--[[
	RobloxStudioAgent.lua — встроенный ИИ-агент Roblox Studio (чат + автономная работа).

	Агент выполняет команды DeepSeek РЕАЛЬНО: создаёт Parts, пишет и правит
	скрипты, удаляет объекты, меняет свойства. DeepSeek не просит ничего
	«вставить вручную» — всё делает сам, командами в скобках:

	  [tree]                                  — осмотреться
	  [add_part="Имя"="X,Y,Z"]                — создать Part
	  [add_script="Путь"]...[/add_script]     — создать/перезаписать скрипт
	  [read_script="Путь"]                    — прочитать код скрипта
	  [delete="Путь"]                         — удалить объект
	  [find="Имя"]                            — найти объекты
	  [set_prop="Путь"="Position: 0,10,0"]    — изменить свойство

	Напоминание об этих командах автоматически добавляется в КАЖДОЕ сообщение,
	чтобы DeepSeek не «забывал» о доступе.

	УСТАНОВКА:
	  1. python deepseek_proxy.py
	  2. Studio: File → Experience Settings → Security → Allow HTTP Requests = ON
	  3. Plugins → Manage Plugins → Install Plugin → этот файл
	  4. Тулбар → «AI Agent» → окно. Пишите задачу — агент делает сам.
--]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- ================= НАСТРОЙКИ =================
local PROXY_URL = "http://localhost:8080/v1/chat/completions"
local DEFAULT_MODEL = "deepseek-chat"
local MAX_AGENT_STEPS = 12
local AGENT_TEMPERATURE = 0.2
local CHAT_TEMPERATURE = 0.7
-- =============================================

-- ЖЁСТКИЙ системный промпт: агент имеет доступ и ОБЯЗАН работать командами
local SYSTEM_AGENT = [[Ты — встроенный ИИ-агент Roblox Studio. У тебя ЕСТЬ ПОЛНЫЙ РЕАЛЬНЫЙ ДОСТУП к Roblox Studio пользователя: ты можешь создавать объекты, писать и редактировать скрипты, удалять объекты. Команды выполняются автоматически, как только ты их напишешь.

ТВОИ КОМАНДЫ (пиши их прямо в ответе):

[tree] — получить дерево объектов (Workspace, ServerScriptService, ReplicatedStorage, StarterGui)
[find="Имя"] — найти объекты по имени (пути придут в результате)
[read_script="ServerScriptService/Имя"] — прочитать код скрипта (код придёт в результате)
[add_script="ServerScriptService/Имя"]
тут весь код скрипта
[/add_script] — создать или ПЕРЕЗАПИСАТЬ скрипт с этим кодом
[add_part="Имя"="X,Y,Z"] — создать Part в Workspace (без координат = 0,10,0)
[set_prop="Workspace/Имя"="Position: 0,10,0"] — изменить свойство (Position, Size, Color RGB, Anchored true/false, Material, Transparency)
[delete="Workspace/Имя"] — удалить объект

ЖЕЛЕЗНЫЕ ПРАВИЛА:
1. НИКОГДА не пиши «вставьте код сами», «я не могу», «у меня нет доступа». У тебя доступ ЕСТЬ. Если что-то не получилось, ты увидишь ошибку в РЕЗУЛЬТАТЕ и исправишь команду.
2. СНАЧАЛА осмотрись ([tree] или [find]), ПОТОМ действуй.
3. После КАЖДОЙ команды тебе придёт сообщение «РЕЗУЛЬТАТ: ...». Читай его и продолжай, пока задача не выполнена полностью.
4. Задача выполнена → ответь БЕЗ команд, коротко: что именно сделано.
5. Скрипты — серверные (Script), код — рабочий Luau без типизации.
6. Можно писать несколько команд в одном ответе.
7. Первое сообщение всегда начинай с [tree], если задача связана с объектами.]]

local SYSTEM_CHAT = "Ты — дружелюбный ассистент по Roblox Studio и Luau. Отвечай кратко. Если просят скрипт — давай чистый код Luau."

-- Напоминание, добавляемое в КАЖДОЕ сообщение агенту
local AGENT_REMINDER = "\n\n(НАПОМИНАНИЕ: ты ИИ-агент Roblox Studio с реальным доступом. Работай ТОЛЬКО командами [tree], [add_part=\"И\"=\"X,Y,Z\"], [add_script=\"Путь\"]...[/add_script], [read_script=\"Путь\"], [set_prop=\"Путь\"=\"Свойство: Значение\"], [delete=\"Путь\"], [find=\"Имя\"]. НЕ проси пользователя ничего вставлять вручную — ты делаешь всё сам.)"

local toolbar = plugin:CreateToolbar("DeepSeek AI Agent")
local toggleBtn = toolbar:CreateButton(
	"AI Agent",
	"Открыть/закрыть окно ИИ-агента",
	"rbxasset://textures/ui/common/robux.png"
)

-- ============================================================
-- Настройки
-- ============================================================

local SETTINGS_KEY = "DeepSeekAgentSettingsV3"
local settings = plugin:GetSetting(SETTINGS_KEY) or {
	model = DEFAULT_MODEL,
	agentMode = true,
	history = nil,
}
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
	"DeepSeekAIAgentV3",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 520, 640, 380, 440)
)
dockGui.Title = "DeepSeek AI Agent — Roblox Studio"

local root = make("Frame", {
	Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(22, 22, 26), BorderSizePixel = 0,
}, dockGui)

-- Шапка: модель + режим
local topBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Color3.fromRGB(30, 30, 36), BorderSizePixel = 0,
}, root)

make("TextLabel", {
	Size = UDim2.fromOffset(44, 32), BackgroundTransparency = 1, Text = "Модель:",
	TextColor3 = Color3.fromRGB(190, 190, 190), Font = Enum.Font.Gotham, TextSize = 12,
}, topBar)

local modelBox = make("TextBox", {
	Size = UDim2.fromOffset(130, 22), Position = UDim2.fromOffset(46, 5),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20), TextColor3 = Color3.fromRGB(230, 230, 230),
	Text = settings.model or DEFAULT_MODEL, ClearTextOnFocus = false, Font = Enum.Font.Code, TextSize = 12,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, modelBox)

local agentMode = settings.agentMode ~= false
local modeCheck = make("TextButton", {
	Size = UDim2.new(0, 150, 0, 22), Position = UDim2.new(1, -156, 0.5, -11),
	BackgroundColor3 = agentMode and Color3.fromRGB(0, 120, 90) or Color3.fromRGB(70, 70, 80),
	Text = agentMode and "🤖 Агент: ВКЛ" or "💬 Только чат",
	TextColor3 = Color3.fromRGB(255, 255, 255), Font = Enum.Font.GothamBold, TextSize = 10,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, modeCheck)

-- Статус
local statusLabel = make("TextLabel", {
	Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(8, 32),
	BackgroundTransparency = 1, Text = "Агент готов. Опишите задачу.",
	TextColor3 = Color3.fromRGB(160, 200, 255), Font = Enum.Font.Gotham, TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, root)

-- Нижняя панель ввода
local inputBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 50), Position = UDim2.new(0, 0, 1, 0),
	AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = Color3.fromRGB(30, 30, 36), BorderSizePixel = 0,
}, root)

local inputBox = make("TextBox", {
	Size = UDim2.new(1, -110, 1, -12), Position = UDim2.fromOffset(6, 6),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20), TextColor3 = Color3.fromRGB(235, 235, 235),
	PlaceholderText = "Задача или вопрос... (Enter — отправить)",
	TextWrapped = true, ClearTextOnFocus = false, Font = Enum.Font.Gotham,
	TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, inputBox)

local sendBtn = make("TextButton", {
	Size = UDim2.fromOffset(92, 38), Position = UDim2.new(1, -98, 0.5, -19),
	BackgroundColor3 = Color3.fromRGB(0, 120, 90), Text = "Отправить",
	TextColor3 = Color3.fromRGB(255, 255, 255), Font = Enum.Font.GothamBold, TextSize = 12,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, sendBtn)

-- Панель быстрых действий
local actionsBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 38), Position = UDim2.new(0, 0, 1, -50),
	AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 1,
}, root)

local lastAnswer = ""
local function quickBtn(text, order)
	return make("TextButton", {
		Size = UDim2.new(0, 150, 0, 28), Position = UDim2.new(0, 8 + (order - 1) * 158, 0, 5),
		BackgroundColor3 = Color3.fromRGB(45, 45, 55), Text = text,
		TextColor3 = Color3.fromRGB(230, 230, 230), Font = Enum.Font.Gotham, TextSize = 11,
	}, actionsBar)
end
local toScriptBtn = quickBtn("💾 Ответ → Script", 1)
local clearHistBtn = quickBtn("🗑 Очистить чат", 2)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, toScriptBtn)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, clearHistBtn)

-- Лента сообщений
local scroll = make("ScrollingFrame", {
	Size = UDim2.new(1, -12, 1, -54 - 96), Position = UDim2.fromOffset(6, 54),
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
	CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, root)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

local msgOrder = 0
local function addBubble(who, text, color)
	msgOrder += 1
	local bubble = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(34, 34, 42),
		Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = msgOrder,
	}, scroll)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 15), Position = UDim2.fromOffset(8, 3),
		BackgroundTransparency = 1, Text = who, TextColor3 = color,
		Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
	}, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 0), Position = UDim2.fromOffset(8, 19),
		BackgroundTransparency = 1, Text = if text ~= "" then text else " ",
		TextColor3 = Color3.fromRGB(225, 225, 225), Font = Enum.Font.Code, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, bubble)
	scroll.CanvasPosition = Vector2.new(0, 1e9)
end

-- Восстановить историю
local history = settings.history or {}
for _, m in ipairs(history) do
	if m.role == "user" then
		addBubble("Вы", m.content, Color3.fromRGB(120, 200, 255))
	elseif m.role == "assistant" then
		addBubble("DeepSeek", m.content, Color3.fromRGB(120, 255, 170))
		lastAnswer = m.content
	end
end

-- ============================================================
-- Утилиты Studio
-- ============================================================

local function findByPath(path)
	local current = game
	for name in string.gmatch(path or "", "[^/]+") do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end
	return current
end

local function commitRecording(recording, ok)
	if recording then
		ChangeHistoryService:FinishRecording(recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
end

-- Парсит значения вида "0,10,0" | "true/false" | "255,0,0" | имя Enum
local function parseValue(propName, raw)
	raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
	local lower = propName:lower()
	local function nums(s)
		local t = {}
		for n in s:gmatch("[-%d%.]+") do t[#t + 1] = tonumber(n) end
		return t
	end
	if lower == "position" or lower == "size" or lower == "rotation" then
		local v = nums(raw)
		if #v >= 3 then
			if lower == "rotation" then
				return CFrame.new(Vector3.new(v[1], v[2], v[3]))
			end
			return Vector3.new(v[1], v[2], v[3])
		end
	end
	if lower == "color" or lower == "color3" then
		local v = nums(raw)
		if #v >= 3 then
			if v[1] > 1 or v[2] > 1 or v[3] > 1 then
				return Color3.fromRGB(v[1], v[2], v[3])
			end
			return Color3.new(v[1], v[2], v[3])
		end
	end
	if raw:lower() == "true" then return true end
	if raw:lower() == "false" then return false end
	if lower == "material" then
		local ok, val = pcall(function() return Enum.Material[raw] end)
		if ok then return val end
	end
	if lower == "shape" then
		local ok, val = pcall(function() return Enum.PartType[raw] end)
		if ok then return val end
	end
	if tonumber(raw) then return tonumber(raw) end
	return raw
end

-- ============================================================
-- Команды агента ([...]-формат)
-- ============================================================

local commands = {}

commands.tree = function()
	local lines = {}
	local function walk(inst, depth)
		if depth > 4 then return end
		lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]"
		for _, child in ipairs(inst:GetChildren()) do walk(child, depth + 1) end
	end
	for _, svc in ipairs({ Workspace, ServerScriptService, game:GetService("ReplicatedStorage"), game:GetService("StarterGui") }) do
		walk(svc, 0)
	end
	if #lines == 0 then lines = { "(пусто)" } end
	return { ok = true, tree = table.concat(lines, "\n") }
end

commands.find = function(arg1)
	local found = {}
	local target = tostring(arg1 or ""):lower()
	if target == "" then return { error = "Пустое имя" } end
	for _, desc in ipairs(game:GetDescendants()) do
		if #found > 30 then break end
		if desc.Name:lower():find(target, 1, true) then
			found[#found + 1] = desc:GetFullName():gsub("^Game%.", "")
		end
	end
	return { ok = true, count = #found, paths = found }
end

commands.read_script = function(arg1)
	local inst = findByPath(arg1)
	if not inst then return { error = "Не найден: " .. tostring(arg1) } end
	if not inst:IsA("LuaSourceContainer") then
		return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
	end
	return { ok = true, source = inst.Source }
end

-- add_script: аргументы = путь + многострочный код (парсится отдельно)
commands.add_script = function(path, source)
	if not path or path == "" then return { error = "Пустой путь" } end
	if not source or source:gsub("%s+", "") == "" then return { error = "Пустой код" } end
	local inst = findByPath(path)
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: add_script")
	if inst then
		if not inst:IsA("LuaSourceContainer") then
			commitRecording(recording, false)
			return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
		end
		inst.Source = source
		commitRecording(recording, true)
		return { ok = true, action = "перезаписан", path = path }
	end
	local parts = {}
	for name in string.gmatch(path, "[^/]+") do parts[#parts + 1] = name end
	local name = table.remove(parts)
	local parent = ServerScriptService
	if #parts > 0 then
		parent = findByPath(table.concat(parts, "/")) or ServerScriptService
	end
	local okNew, err = pcall(function()
		local s = Instance.new("Script")
		s.Name = name
		s.Source = source
		s.Parent = parent
	end)
	if not okNew then
		commitRecording(recording, false)
		return { error = "Не удалось создать Script: " .. tostring(err) }
	end
	commitRecording(recording, true)
	return { ok = true, action = "создан", path = path }
end

commands.add_part = function(arg1, arg2)
	local name = arg1 or "Part"
	local pos = Vector3.new(0, 10, 0)
	if arg2 and arg2 ~= "" then
		local v = {}
		for n in arg2:gmatch("[-%d%.]+") do v[#v + 1] = tonumber(n) end
		if #v >= 3 then pos = Vector3.new(v[1], v[2], v[3]) end
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: add_part")
	local ok, err = pcall(function()
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Vector3.new(4, 1, 4)
		p.Position = pos
		p.Anchored = true
		p.Parent = Workspace
	end)
	if not ok then
		commitRecording(recording, false)
		return { error = tostring(err) }
	end
	commitRecording(recording, true)
	return { ok = true, created = "Part '" .. name .. "' в Workspace, Position " .. tostring(pos) }
end

commands.set_prop = function(arg1, arg2)
	local inst = findByPath(arg1)
	if not inst then return { error = "Не найден: " .. tostring(arg1) } end
	local propName, raw = (arg2 or ""):match("^%s*([%w_]+)%s*:%s*(.+)$")
	if not propName then return { error = "Формат: [set_prop=\"Путь\"=\"Свойство: Значение\"]" } end
	local val = parseValue(propName, raw)
	local okSet, err = pcall(function() inst[propName] = val end)
	if not okSet then
		return { error = "Свойство " .. propName .. ": " .. tostring(err) }
	end
	return { ok = true, set = arg1 .. "." .. propName .. " = " .. tostring(val) }
end

commands.delete = function(arg1)
	local inst = findByPath(arg1)
	if not inst then return { error = "Не найден: " .. tostring(arg1) } end
	if inst:IsA("ServerScriptService") or inst:IsA("Workspace") then
		return { error = "Нельзя удалять сервисы" }
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: delete")
	inst:Destroy()
	commitRecording(recording, true)
	return { ok = true, deleted = arg1 }
end

-- ============================================================
-- Парсер команд из текста модели
-- ============================================================

-- Однострочные: [cmd="arg1"="arg2"], [cmd="arg1"], [cmd]
local SINGLE_LINE_COMMANDS = { "tree", "find", "read_script", "add_part", "set_prop", "delete" }

local function extractCommands(text)
	local list = {} -- {cmd=..., arg1=..., arg2=..., source=...}

	-- 1) Многострочные add_script: [add_script="Путь"] код [/add_script]
	local rest = text
	while true do
		local openStart, _, path = rest:find('%[add_script%s*=%s*"([^"]*)"%]')
		if not openStart then break end
		local closeStart, closeEnd = rest:find("%[%/add_script%]", openStart)
		local code
		local consumed
		if closeStart then
			code = rest:sub(openStart, closeStart - 1)
			-- убираем ведущий перевод строки после открывающего тега
			code = code:gsub("^%s*\n", "")
			consumed = closeEnd
		else
			-- нет закрывающего тега — код до конца текста
			code = rest:sub(openStart)
			code = code:gsub("^%s*\n", "")
			consumed = #rest
		end
		list[#list + 1] = { cmd = "add_script", arg1 = path, source = code }
		rest = rest:sub(1, openStart - 1) .. " " .. rest:sub(consumed + 1)
	end

	-- 2) Однострочные команды ([cmd="a"="b"], [cmd="a"], [cmd])
	for _, cmdName in ipairs(SINGLE_LINE_COMMANDS) do
		for arg1, arg2 in rest:gmatch('%[' .. cmdName .. '%s*=%s*"(.-)"%s*=%s*"(.-)"%]') do
			list[#list + 1] = { cmd = cmdName, arg1 = arg1, arg2 = arg2 }
		end
		for arg1 in rest:gmatch('%[' .. cmdName .. '%s*=%s*"(.-)"%]') do
			list[#list + 1] = { cmd = cmdName, arg1 = arg1 }
		end
		if rest:find("%[" .. cmdName .. "%]") then
			list[#list + 1] = { cmd = cmdName }
		end
	end

	return list
end

local function stripCommands(text)
	local out = text
	out = out:gsub('%[add_script%s*=%s*"[^"]*"%].-%[%/add_script%]', "")
	out = out:gsub('%[%w+%s*=%s*"[^"]*"%s*=%s*"[^"]*"%]', "")
	out = out:gsub('%[%w+%s*=%s*"[^"]*"%]', "")
	out = out:gsub("%[%w+%]", "")
	out = out:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
	return out
end

local function stripCodeFence(source)
	local body = source:match("```%w*%s*(.-)```")
	if body and #body > 0 then return body end
	return source:gsub("```%w*", ""):gsub("```", "")
end

-- ============================================================
-- Запрос к прокси (с напоминанием в КАЖДОЕ сообщение)
-- ============================================================

local function callProxy(messages, temperature, isAgent)
	-- Клонируем и добавляем напоминание агенту в последнее user-сообщение
	local payload = {}
	for i, m in ipairs(messages) do
		payload[i] = { role = m.role, content = m.content }
	end
	if isAgent and #payload > 0 and payload[#payload].role == "user" then
		payload[#payload].content = payload[#payload].content .. AGENT_REMINDER
	end

	local response = HttpService:RequestAsync({
		Url = PROXY_URL, Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer any-key",
		},
		Body = HttpService:JSONEncode({
			model = modelBox.Text ~= "" and modelBox.Text or DEFAULT_MODEL,
			messages = payload,
			temperature = temperature,
		}),
	})
	if not response.Success then
		error("HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.Body):sub(1, 200))
	end
	local data = HttpService:JSONDecode(response.Body)
	if data.error then error("Прокси: " .. tostring(data.error.message or data.error)) end
	return data.choices[1].message.content
end

-- ============================================================
-- Два режима
-- ============================================================

local busy = false
local function setBusy(b, statusText)
	busy = b
	sendBtn.Text = b and "..." or "Отправить"
	sendBtn.AutoButtonColor = not b
	statusLabel.Text = statusText or (b and "Работаю..." or "Готов. Опишите задачу.")
end

local function runChat(userText, messages)
	setBusy(true, "DeepSeek думает...")
	local ok, answer = pcall(callProxy, messages, CHAT_TEMPERATURE, false)
	if not ok then
		addBubble("ОШИБКА", "Нет связи с прокси. Запущен ли deepseek_proxy.py?\n" .. tostring(answer), Color3.fromRGB(255, 110, 110))
		setBusy(false)
		return
	end
	lastAnswer = answer
	messages[#messages + 1] = { role = "assistant", content = answer }
	settings.history = messages
	saveSettings()
	addBubble("DeepSeek", answer, Color3.fromRGB(120, 255, 170))
	setBusy(false)
end

local function runAgent(userTask)
	local messages = {
		{ role = "system", content = SYSTEM_AGENT },
		{ role = "user", content = userTask },
	}

	for step = 1, MAX_AGENT_STEPS do
		setBusy(true, "Агент: шаг " .. step .. "/" .. MAX_AGENT_STEPS .. " — думаю...")

		local ok, answer = pcall(callProxy, messages, AGENT_TEMPERATURE, true)
		if not ok then
			addBubble("ОШИБКА", "Нет связи с прокси. Запущен ли deepseek_proxy.py?\n" .. tostring(answer), Color3.fromRGB(255, 110, 110))
			setBusy(false)
			return
		end

		local visible = stripCommands(answer)
		if visible ~= "" then
			addBubble("Агент · шаг " .. step, visible, Color3.fromRGB(120, 255, 170))
		end

		local cmds = extractCommands(answer)
		if #cmds == 0 then
			history = messages
			settings.history = history
			saveSettings()
			addBubble("✅ ГОТОВО", "Задача выполнена за " .. step .. " шаг(ов).", Color3.fromRGB(255, 210, 100))
			setBusy(false)
			return
		end

		local results = {}
		for i, c in ipairs(cmds) do
			local handler = commands[c.cmd]
			local result
			if not handler then
				result = { error = "Неизвестная команда: " .. tostring(c.cmd) }
			else
				local okExec, res = pcall(handler, c.arg1, c.arg2, c)
				result = okExec and res or { error = tostring(res) }
			end
			addBubble("⚙ " .. tostring(c.cmd) .. " #" .. i,
				HttpService:JSONEncode(result):sub(1, 600), Color3.fromRGB(160, 160, 255))
			results[#results + 1] = "РЕЗУЛЬТАТ команды " .. tostring(c.cmd) .. " #" .. i .. ": " .. HttpService:JSONEncode(result)
		end

		messages[#messages + 1] = { role = "assistant", content = answer }
		messages[#messages + 1] = {
			role = "user",
			content = table.concat(results, "\n")
				.. "\n\nПродолжай выполнение задачи командами. Если всё готово — ответь без команд, кратко описав сделанное.",
		}
	end

	addBubble("⚠️ ЛИМИТ", "Достигнут лимит " .. MAX_AGENT_STEPS .. " шагов. Напишите «продолжай».", Color3.fromRGB(255, 160, 100))
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
	addBubble("Вы", text, Color3.fromRGB(120, 200, 255))

	if agentMode then
		task.spawn(runAgent, text)
	else
		history[#history + 1] = { role = "user", content = text }
		if #history == 1 or history[1].role ~= "system" then
			table.insert(history, 1, { role = "system", content = SYSTEM_CHAT })
		end
		task.spawn(runChat, text, history)
	end
end

sendBtn.MouseButton1Click:Connect(startTask)
inputBox.FocusLost:Connect(function(enter)
	if enter then startTask() end
end)

modeCheck.MouseButton1Click:Connect(function()
	agentMode = not agentMode
	settings.agentMode = agentMode
	saveSettings()
	modeCheck.Text = agentMode and "🤖 Агент: ВКЛ" or "💬 Только чат"
	modeCheck.BackgroundColor3 = agentMode and Color3.fromRGB(0, 120, 90) or Color3.fromRGB(70, 70, 80)
end)

toScriptBtn.MouseButton1Click:Connect(function()
	if lastAnswer == "" then
		addBubble("СИСТЕМА", "Сначала получите ответ.", Color3.fromRGB(255, 200, 100))
		return
	end
	local source = stripCodeFence(lastAnswer)
	local name, i = "AIScript", 1
	while ServerScriptService:FindFirstChild(name) do
		i += 1
		name = "AIScript" .. i
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: answer to Script")
	local ok, err = pcall(function()
		local s = Instance.new("Script")
		s.Name = name
		s.Source = source
		s.Parent = ServerScriptService
	end)
	commitRecording(recording, ok)
	addBubble("СИСТЕМА", ok and ("Сохранено: ServerScriptService/" .. name) or ("Ошибка: " .. tostring(err)), Color3.fromRGB(255, 200, 100))
end)

clearHistBtn.MouseButton1Click:Connect(function()
	history = {}
	lastAnswer = ""
	settings.history = nil
	saveSettings()
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	msgOrder = 0
	addBubble("СИСТЕМА", "Чат очищен.", Color3.fromRGB(255, 200, 100))
end)

modelBox.FocusLost:Connect(function(enter)
	if enter then
		settings.model = modelBox.Text
		saveSettings()
		addBubble("СИСТЕМА", "Модель сохранена: " .. modelBox.Text, Color3.fromRGB(255, 200, 100))
	end
end)

toggleBtn.Click:Connect(function()
	dockGui.Enabled = not dockGui.Enabled
end)

plugin.Unloading:Connect(saveSettings)
