--[[
	RobloxStudioAgent.lua — ПОЛНОЦЕННЫЙ ИИ-АГЕНТ для Roblox Studio.

	Чем отличается от обычного чата: агент не только отвечает, но и САМ
	выполняет действия в Studio через инструменты (tools):
	  • обходит дерево объектов
	  • читает и РЕДАКТИРУЕТ скрипты
	  • создаёт и удаляет объекты (Part, Script, Folder, любые классы)
	  • меняет свойства (Position, Color, Size, Name, ...)
	  • ищет объекты по имени
	После каждого действия он видит результат и решает, что делать дальше —
	как настоящий агент: «посмотрел дерево → прочитал скрипт → исправил → проверил».

	Работает через локальный прокси deepseek_proxy.py (localhost:8080).
	Ключ — любой (прокси его не проверяет), поле «Ключ» в окне.

	УСТАНОВКА:
	  1. Запустите: python deepseek_proxy.py
	  2. Studio: File → Experience Settings → Security → Allow HTTP Requests = ON
	  3. Plugins → Manage Plugins → Install Plugin → выберите этот файл
	  4. Тулбар → кнопка «AI Agent» → окно агента.
	  5. Напишите задачу, например:
	     «Создай скрипт ServerScriptService/Door, который открывает Part
	      с именем DoorPart при нажатии, и создай этот Part».
	     Дальше агент всё сделает сам.
--]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- ================= НАСТРОЙКИ =================
local PROXY_URL = "http://localhost:8080/v1/chat/completions"
local DEFAULT_MODEL = "deepseek-chat"
local MAX_AGENT_STEPS = 10 -- максимум действий агента за одну задачу
-- =============================================

-- Системный промпт: описывает агента и формат инструментов
local SYSTEM_PROMPT = [[Ты — автономный ИИ-агент внутри Roblox Studio. Ты выполняешь задачи пользователя САМ, шаг за шагом, используя инструменты.

ДОСТУПНЫЕ ИНСТРУМЕНТЫ. Каждый вызов — отдельный блок ```tool ... ``` с JSON внутри:
{"tool":"get_tree"} — получить дерево объектов Workspace/ServerScriptService/ReplicatedStorage/StarterGui
{"tool":"read_script","path":"ServerScriptService/MyScript"} — прочитать код скрипта
{"tool":"write_script","path":"ServerScriptService/MyScript","source":"print(1)"} — создать или перезаписать скрипт
{"tool":"create_instance","className":"Part","name":"MyPart","parent":"Workspace","properties":{"Position":{"Vector3":[0,10,0]},"Anchored":true,"Color":{"Color3":[255,0,0]}}} — создать объект и задать свойства
{"tool":"delete_instance","path":"Workspace/MyPart"} — удалить объект
{"tool":"set_property","path":"Workspace/MyPart","property":"Position","value":{"Vector3":[5,10,5]}} — изменить свойство
{"tool":"find_instances","name":"Door"} — найти все объекты с таким именем

ПРАВИЛА:
1. За один ответ вызывай ОДИН или НЕСКОЛЬКО инструментов в блоках ```tool ```.
2. После каждого вызова ты получишь РЕЗУЛЬТАТ — анализируй его и действуй дальше.
3. Когда задача полностью выполнена, ответь БЕЗ блоков tool, коротко объяснив, что сделано.
4. Пиши код Luau с учётом версии без типизации, скрипты — обычные Script (серверные).
5. Пути — вида "ServerScriptService/Имя" или "Workspace/Папка/Объект".]]

local toolbar = plugin:CreateToolbar("DeepSeek AI Agent")
local toggleBtn = toolbar:CreateButton(
	"AI Agent",
	"Открыть/закрыть окно ИИ-агента",
	"rbxasset://textures/ui/common/robux.png"
)

-- ============================================================
-- Настройки (сохраняются между запусками)
-- ============================================================

local SETTINGS_KEY = "DeepSeekAgentSettings"
local settings = plugin:GetSetting(SETTINGS_KEY) or { apiKey = "any-key", model = DEFAULT_MODEL }
local function saveSettings()
	pcall(function() plugin:SetSetting(SETTINGS_KEY, settings) end)
end

-- ============================================================
-- GUI
-- ============================================================

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do inst[k] = v end
	inst.Parent = parent
	return inst
end

local dockGui = plugin:CreateDockWidgetPluginGui(
	"DeepSeekAIAgent",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 500, 620, 360, 420)
)
dockGui.Title = "DeepSeek AI Agent — Roblox"

local root = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(22, 22, 26),
	BorderSizePixel = 0,
}, dockGui)

-- Верхняя панель: ключ и модель
local topBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundColor3 = Color3.fromRGB(30, 30, 36),
	BorderSizePixel = 0,
}, root)

make("TextLabel", {
	Size = UDim2.fromOffset(38, 32), BackgroundTransparency = 1,
	Text = "Ключ:", TextColor3 = Color3.fromRGB(190, 190, 190),
	Font = Enum.Font.Gotham, TextSize = 12,
}, topBar)

local keyBox = make("TextBox", {
	Size = UDim2.new(1, -230, 1, -10), Position = UDim2.fromOffset(42, 5),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20), TextColor3 = Color3.fromRGB(230, 230, 230),
	Text = settings.apiKey or "any-key", PlaceholderText = "любой ключ",
	ClearTextOnFocus = false, Font = Enum.Font.Code, TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, keyBox)

local saveKeyBtn = make("TextButton", {
	Size = UDim2.fromOffset(62, 22), Position = UDim2.new(1, -184, 0.5, -11),
	BackgroundColor3 = Color3.fromRGB(0, 120, 90), Text = "Сохранить",
	TextColor3 = Color3.fromRGB(255, 255, 255), Font = Enum.Font.GothamBold, TextSize = 11,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, saveKeyBtn)

local modelBox = make("TextBox", {
	Size = UDim2.fromOffset(110, 22), Position = UDim2.new(1, -116, 0.5, -11),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20), TextColor3 = Color3.fromRGB(230, 230, 230),
	Text = settings.model or DEFAULT_MODEL, ClearTextOnFocus = false,
	Font = Enum.Font.Code, TextSize = 12,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, modelBox)

-- Статус агента
local statusLabel = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 32),
	BackgroundTransparency = 1, Text = "Агент готов. Опишите задачу.",
	TextColor3 = Color3.fromRGB(160, 200, 255), Font = Enum.Font.Gotham,
	TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
}, root)
statusLabel.Position = UDim2.fromOffset(8, 32)

-- Лента сообщений
local scroll = make("ScrollingFrame", {
	Size = UDim2.new(1, -12, 1, -110), Position = UDim2.fromOffset(6, 56),
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
	CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, root)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

local msgOrder = 0
local function addBubble(who, text, color)
	msgOrder += 1
	local bubble = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(34, 34, 42),
		Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = msgOrder,
	}, scroll)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(8, 3),
		BackgroundTransparency = 1, Text = who, TextColor3 = color,
		Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
	}, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 0), Position = UDim2.fromOffset(8, 20),
		BackgroundTransparency = 1, Text = text, TextColor3 = Color3.fromRGB(225, 225, 225),
		Font = Enum.Font.Code, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y,
	}, bubble)
	scroll.CanvasPosition = Vector2.new(0, 1e9)
end

-- Нижняя панель: ввод
local inputBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 50), Position = UDim2.new(1, 0, 1, -50),
	AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = Color3.fromRGB(30, 30, 36),
	BorderSizePixel = 0,
}, root)

local inputBox = make("TextBox", {
	Size = UDim2.new(1, -110, 1, -12), Position = UDim2.fromOffset(6, 6),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20), TextColor3 = Color3.fromRGB(235, 235, 235),
	PlaceholderText = "Задача для агента... (Enter — запустить)",
	TextWrapped = true, ClearTextOnFocus = false, Font = Enum.Font.Gotham,
	TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, inputBox)

local sendBtn = make("TextButton", {
	Size = UDim2.fromOffset(92, 38), Position = UDim2.new(1, -98, 0.5, -19),
	BackgroundColor3 = Color3.fromRGB(0, 120, 90), Text = "Запустить",
	TextColor3 = Color3.fromRGB(255, 255, 255), Font = Enum.Font.GothamBold, TextSize = 12,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, sendBtn)

-- ============================================================
-- ИНСТРУМЕНТЫ АГЕНТА (выполнение в Studio)
-- ============================================================

local function findByPath(path)
	local current = game
	for name in string.gmatch(path or "", "[^/]+") do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end
	return current
end

-- Преобразует JSON-значение в значение свойства Roblox
local function toPropertyValue(value)
	if type(value) ~= "table" then
		return value -- строка/число/булево
	end
	if value.Vector3 then
		local v = value.Vector3
		return Vector3.new(tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0)
	end
	if value.Color3 then
		local c = value.Color3
		-- Поддержка 0-255 и 0-1: если все > 1, считаем 0-255
		local a, b, d = tonumber(c[1]) or 0, tonumber(c[2]) or 0, tonumber(c[3]) or 0
		if a > 1 or b > 1 or d > 1 then
			return Color3.fromRGB(a, b, d)
		end
		return Color3.new(a, b, d)
	end
	if value.UDim2 then
		local u = value.UDim2
		return UDim2.new(tonumber(u[1]) or 0, tonumber(u[2]) or 0, tonumber(u[3]) or 0, tonumber(u[4]) or 0)
	end
	if value.Enum then
		-- {"Enum": ["Material", "Neon"]} → Enum.Material.Neon			local ok, val = pcall(function()
				return Enum[value.Enum[1]][value.Enum[2]]
			end)
		if ok then return val end
		return nil
	end
	return value
end

local tools = {}

tools.get_tree = function(_)
	local lines = {}
	local function walk(inst, depth)
		if depth > 4 then return end
		lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]"
		for _, child in ipairs(inst:GetChildren()) do
			walk(child, depth + 1)
		end
	end
	for _, svc in ipairs({ Workspace, ServerScriptService, game:GetService("ReplicatedStorage"), game:GetService("StarterGui") }) do
		walk(svc, 0)
	end
	if #lines == 0 then lines = { "(пусто)" } end
	return { ok = true, tree = table.concat(lines, "\n") }
end

tools.read_script = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Объект не найден: " .. tostring(args.path) } end
	if not inst:IsA("LuaSourceContainer") then
		return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
	end
	return { ok = true, path = args.path, source = inst.Source }
end

tools.write_script = function(args)
	local inst = findByPath(args.path)
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: write_script")
	local className = "Script"
	if inst then
		-- Перезаписываем существующий, сохраняя его класс
		if not inst:IsA("LuaSourceContainer") then
			if recording then ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel) end
			return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
		end
		inst.Source = args.source
		if recording then ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit) end
		return { ok = true, action = "updated", path = args.path }
	end
	-- Создаём новый: родитель = всё до последнего сегмента пути
	local parts = {}
	for name in string.gmatch(args.path or "", "[^/]+") do parts[#parts + 1] = name end
	if #parts == 0 then return { error = "Пустой путь" } end
	local name = table.remove(parts)
	local parent = game
	if #parts > 0 then
		parent = findByPath(table.concat(parts, "/"))
	end
	if parent == game then parent = ServerScriptService end
	if not parent then
		if recording then ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel) end
		return { error = "Родитель не найден: " .. table.concat(parts, "/") }
	end
	if not parent:IsA("LuaSourceContainer") and not parent:IsA("Actor") and not parent:IsA("Model") and not parent:IsA("Folder") and not parent:IsA("ServerScriptService") and not parent:IsA("ReplicatedStorage") and not parent:IsA("StarterPlayer") then
		-- родитель может быть любым контейнером — пропускаем проверку, Instance.new всё равно упадёт с ошибкой если нельзя
	end
	local newScript = Instance.new(className)
	newScript.Name = name
	newScript.Source = args.source
	newScript.Parent = parent
	if recording then ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit) end
	return { ok = true, action = "created", path = args.path }
end

tools.create_instance = function(args)
	local ok, inst = pcall(function() return Instance.new(args.className) end)
	if not ok then return { error = "Не удалось создать класс: " .. tostring(args.className) } end
	inst.Name = args.name or args.className
	-- Свойства до парента (чтобы Part не падал под Baseplate до установки Position)
	local propErrors = {}
	for prop, value in pairs(args.properties or {}) do
		local okProp, val = pcall(toPropertyValue, value)
		if okProp and val ~= nil then
			local okSet = pcall(function() inst[prop] = val end)
			if not okSet then propErrors[#propErrors + 1] = prop end
		end
	end
	local parent = findByPath(args.parent or "Workspace") or Workspace
	inst.Parent = parent
	-- Путь результата
	local parts = { parent:GetFullName():gsub("Game", "Workspace") }
	local result = { ok = true, created = inst.Name, class = inst.ClassName }
	if #propErrors > 0 then
		result.warning = "Не удалось задать свойства: " .. table.concat(propErrors, ", ")
	end
	return result
end

tools.delete_instance = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Объект не найден: " .. tostring(args.path) } end
	if inst:IsA("ServerScriptService") or inst:IsA("Workspace") then
		return { error = "Нельзя удалять сервисы" }
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: delete_instance")
	inst:Destroy()
	if recording then ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit) end
	return { ok = true, deleted = args.path }
end

tools.set_property = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Объект не найден: " .. tostring(args.path) } end
	local ok, val = pcall(toPropertyValue, args.value)
	if not ok or val == nil then return { error = "Некорректное значение свойства" } end
	local okSet, err = pcall(function() inst[args.property] = val end)
	if not okSet then return { error = "Свойство " .. tostring(args.property) .. ": " .. tostring(err) } end
	return { ok = true, set = args.path .. "." .. tostring(args.property) }
end

tools.find_instances = function(args)
	local found = {}
	for _, desc in ipairs(game:GetDescendants()) do
		if #found > 30 then break end
		if desc.Name:lower() == tostring(args.name):lower() then
			found[#found + 1] = desc:GetFullName():gsub("^Game%.", "")
		end
	end
	return { ok = true, matches = found, count = #found }
end

-- ============================================================
-- Парсинг ответа ИИ: блоки ```tool {json} ```
-- ============================================================

local function extractToolCalls(text)
	local calls = {}
	for body in text:gmatch("```tool%s*(.-)```") do
		local decoded = HttpService:JSONDecode(body)
		calls[#calls + 1] = decoded
	end
	return calls
end

local function stripToolBlocks(text)
	return (text:gsub("```tool%s*(.-)```", ""):gsub("\n\n+", "\n"):gsub("^%s+", ""))
end

-- ============================================================
-- Агентный цикл
-- ============================================================

local busy = false

local function setBusy(b, statusText)
	busy = b
	sendBtn.Text = b and "..." or "Запустить"
	sendBtn.AutoButtonColor = not b
	statusLabel.Text = statusText or (b and "Агент работает..." or "Агент готов. Опишите задачу.")
end

local function callProxy(messages)
	local response = HttpService:RequestAsync({
		Url = PROXY_URL,
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. (keyBox.Text ~= "" and keyBox.Text or "any-key"),
		},
		Body = HttpService:JSONEncode({
			model = modelBox.Text ~= "" and modelBox.Text or DEFAULT_MODEL,
			messages = messages,
			temperature = 0.2,
		}),
	})
	if not response.Success then
		error("HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.Body):sub(1, 200))
	end
	local data = HttpService:JSONDecode(response.Body)
	if data.error then
		error("Прокси: " .. tostring(data.error.message or data.error))
	end
	return data.choices[1].message.content
end

local function runAgent(userTask)
	messages = { { role = "system", content = SYSTEM_PROMPT } }
	messages[#messages + 1] = { role = "user", content = userTask }

	for step = 1, MAX_AGENT_STEPS do
		setBusy(true, "Агент: шаг " .. step .. " из " .. MAX_AGENT_STEPS .. " — думает...")

		local ok, answer = pcall(callProxy, messages)
		if not ok then
			addBubble("ОШИБКА", "Связь с прокси: " .. tostring(answer)
				.. "\nПроверьте: запущен ли deepseek_proxy.py и Allow HTTP Requests = ON.",
				Color3.fromRGB(255, 110, 110))
			setBusy(false)
			return
		end

		-- Показываем ответ агента (без техблоков — они ниже отдельными строками)
		local visible = stripToolBlocks(answer)
		if visible ~= "" then
			addBubble("Агент (шаг " .. step .. ")", visible, Color3.fromRGB(120, 255, 170))
		end

		local calls = extractToolCalls(answer)

		if #calls == 0 then
			-- Инструментов нет — агент считает задачу выполненной
			addBubble("✅ ГОТОВО", "Агент завершил задачу за " .. step .. " шаг(ов).", Color3.fromRGB(255, 210, 100))
			setBusy(false)
			return
		end

		-- Выполняем инструменты и собираем результаты
		local resultsText = {}
		for i, call in ipairs(calls) do
			local toolName = call.tool
			local handler = toolName and tools[toolName]
			local result
			if not handler then
				result = { error = "Неизвестный инструмент: " .. tostring(toolName) }
			else
				local okExec, res = pcall(handler, call)
				result = okExec and res or { error = tostring(res) }
			end
			addBubble("🔧 " .. tostring(toolName),
				HttpService:JSONEncode(result):sub(1, 400),
				Color3.fromRGB(160, 160, 255))
			resultsText[#resultsText + 1] = "РЕЗУЛЬТАТ инструмента " .. tostring(toolName)
				.. " #" .. i .. ": " .. HttpService:JSONEncode(result)
		end

		-- Скармливаем результаты агенту для следующего шага
		messages[#messages + 1] = { role = "assistant", content = answer }
		messages[#messages + 1] = { role = "user", content = table.concat(resultsText, "\n") .. "\n\nПродолжай выполнение задачи. Если всё готово — ответь без блоков tool." }
	end

	addBubble("⚠️ СТОП", "Достигнут лимит шагов (" .. MAX_AGENT_STEPS .. "). Задача, возможно, не завершена — уточните и продолжите.", Color3.fromRGB(255, 160, 100))
	setBusy(false)
end

-- ============================================================
-- События
-- ============================================================

local function startTask()
	if busy then return end
	local text = inputBox.Text
	if text == "" then return end
	inputBox.Text = ""
	addBubble("ЗАДАЧА", text, Color3.fromRGB(120, 200, 255))
	task.spawn(runAgent, text)
end

sendBtn.MouseButton1Click:Connect(startTask)
inputBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then startTask() end
end)

saveKeyBtn.MouseButton1Click:Connect(function()
	settings.apiKey = keyBox.Text
	settings.model = modelBox.Text
	saveSettings()
	addBubble("СИСТЕМА", "Настройки сохранены.", Color3.fromRGB(255, 200, 100))
end)

toggleBtn.Click:Connect(function()
	dockGui.Enabled = not dockGui.Enabled
end)

plugin.Unloading:Connect(saveSettings)
