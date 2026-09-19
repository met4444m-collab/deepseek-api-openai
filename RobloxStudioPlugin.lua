--[[
	RobloxStudioPlugin.lua — плагин для Roblox Studio.

	Слушает команды от MCP-сервера (robomcp.py, http://localhost:3001)
	и выполняет их внутри Studio: читает/пишет скрипты, создаёт/удаляет объекты.

	УСТАНОВКА:
	  1. Сохраните этот файл как RobloxStudioPlugin.lua.
	  2. Roblox Studio: Plugins → Manage Plugins → Install Plugin → выберите файл.
	  3. Включите HTTP-запросы: File → Experience Settings → Security →
	     Allow HTTP Requests = ON.
	  4. Запустите robomcp.py и откройте в Studio любое место (place).
	  5. Плагин запустится автоматически (вкладка PLUGIN → RoboMCP → Toggle).
--]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- Адрес MCP-сервера (robomcp.py)
local SERVER_URL = "http://localhost:3001"

-- Интервал опроса команд (секунды)
local POLL_INTERVAL = 1

local running = false

-- ============================================================
-- Утилиты
-- ============================================================

-- Выполняет HTTP-запрос к MCP-серверу. Возвращает таблицу или nil при ошибке.
local function sendRequest(method, path, body)
	local url = SERVER_URL .. path
	local options = {
		Url = url,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
	}
	if body then
		options.Body = HttpService:JSONEncode(body)
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if not ok then
		warn("[RoboMCP] HTTP-запрос не выполнен: " .. tostring(response))
		return nil
	end
	if not response.Success then
		warn("[RoboMCP] Сервер вернул " .. tostring(response.StatusCode)
			.. ": " .. tostring(response.Body))
		return nil
	end

	local decoded, decodedData = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decoded then
		warn("[RoboMCP] Не удалось распарсить ответ сервера")
		return nil
	end
	return decodedData
end

-- Находит Instance по пути вида "ServerScriptService/MyFolder/MyScript".
local function findByPath(path)
	local current = game
	for name in string.gmatch(path, "[^/]+") do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

-- Строит относительный путь объекта внутри DataModel (для дерева файлов).
local function pathOf(instance)
	if not instance or instance == game then
		return ""
	end
	local parts = {}
	local current = instance
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, "/")
end

-- ============================================================
-- Обработчики команд
-- ============================================================

-- Рекурсивно собирает дерево объектов (с ограничением глубины, чтобы не виснуть).
local function buildTree(instance, depth, maxDepth)
	local node = {
		name = instance.Name,
		className = instance.ClassName,
		path = pathOf(instance),
		children = {},
	}
	if depth < maxDepth then
		for _, child in ipairs(instance:GetChildren()) do
			table.insert(node.children, buildTree(child, depth + 1, maxDepth))
		end
	elseif #instance:GetChildren() > 0 then
		node.truncated = true
	end
	return node
end

local handlers = {}

-- Дерево объектов DataModel
handlers.file_tree = function(command)
	local tree = buildTree(game, 0, 4)
	return { id = command.id, tree = tree }
end

-- Прочитать код скрипта: {path = "ServerScriptService/MyScript"}
handlers.read_script = function(command)
	local inst = findByPath(command.path)
	if not inst then
		return { id = command.id, error = "Объект не найден: " .. tostring(command.path) }
	end
	if not inst:IsA("LuaSourceContainer") then
		return { id = command.id, error = "Объект не скрипт: " .. inst.ClassName }
	end
	return { id = command.id, source = inst.Source }
end

-- Сохранить код в скрипт: {path = "...", source = "..."}
handlers.write_script = function(command)
	local inst = findByPath(command.path)
	if not inst then
		return { id = command.id, error = "Объект не найден: " .. tostring(command.path) }
	end
	if not inst:IsA("LuaSourceContainer") then
		return { id = command.id, error = "Объект не скрипт: " .. inst.ClassName }
	end
	-- Записываем через ChangeHistoryService, чтобы работало Undo (Ctrl+Z)
	local recording = ChangeHistoryService:TryBeginRecording("RoboMCP: edit script")
	if recording then
		inst.Source = command.source
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	else
		inst.Source = command.source
	end
	return { id = command.id, success = true }
end

-- Создать объект: {className, name, parent = "Workspace" или путь}
handlers.create_instance = function(command)
	local ok, inst = pcall(function()
		return Instance.new(command.className)
	end)
	if not ok then
		return { id = command.id, error = "Не удалось создать " .. tostring(command.className) }
	end
	inst.Name = command.name

	local parent
	if command.parent and command.parent ~= "game" then
		parent = findByPath(command.parent) or workspace
	else
		parent = workspace
	end
	inst.Parent = parent
	return { id = command.id, success = true, path = pathOf(inst) }
end

-- Удалить объект: {path = "..."}
handlers.delete_instance = function(command)
	local inst = findByPath(command.path)
	if not inst then
		return { id = command.id, error = "Объект не найден: " .. tostring(command.path) }
	end
	inst:Destroy()
	return { id = command.id, success = true }
end

-- ============================================================
-- Основной цикл: опрашивает MCP-сервер и выполняет команды
-- ============================================================

local function pollOnce()
	-- Забираем команду (может прийти {action = nil} — команд нет)
	local command = sendRequest("GET", "/api/command")
	if not command or not command.action then
		return
	end

	local handler = handlers[command.action]
	if not handler then
		warn("[RoboMCP] Неизвестная команда: " .. tostring(command.action))
		return
	end

	-- Выполняем и возвращаем результат
	local ok, result = pcall(handler, command)
	if not ok then
		warn("[RoboMCP] Ошибка выполнения команды: " .. tostring(result))
		sendRequest("POST", "/api/response", {
			id = command.id,
			error = tostring(result),
		})
	else
		sendRequest("POST", "/api/response", result)
	end
end

-- Создаём кнопку в тулбаре плагинов для запуска/остановки
local toolbar = plugin:CreateToolbar("RoboMCP")
local toggleButton = toolbar:CreateButton(
	"RoboMCP",
	"Включить/выключить MCP-мост",
	"rbxasset://textures/animationEditor/play.png"
)

local connection = nil

local function startLoop()
	if running then
		return
	end
	running = true
	toggleButton:SetActive(true)
	-- Опрашиваем сервер, пока плагин включён
	task.spawn(function()
		while running do
			pollOnce()
			task.wait(POLL_INTERVAL)
		end
	end)
end

local function stopLoop()
	running = false
	toggleButton:SetActive(false)
end

toggleButton.Click:Connect(function()
	if running then
		stopLoop()
	else
		startLoop()
	end
end)

-- Запускаем мост автоматически при загрузке плагина
startLoop()

-- Останавливаем выгрузку плагина корректно
plugin.Unloading:Connect(stopLoop)
