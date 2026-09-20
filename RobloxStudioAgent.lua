--[[
	RobloxStudioAgent.lua — встроенный ИИ-агент Roblox Studio (чат + автономная работа).

	ОДИН файл-плагин:
	  • ОКНО ЧАТА как в мессенджере: пузыри, история, Enter = отправить.
	  • РЕЖИМ АГЕНТА (включён по умолчанию): DeepSeek не просто отвечает, а САМ
	    выполняет действия в Studio — читает/пишет скрипты, создаёт/удаляет
	    объекты, меняет свойства, ищет по имени — шаг за шагом до результата.
	  • РЕЖИМ ЧАТА (галочка «Только чат»): обычное общение без действий.
	  • Кнопка «Ответ → Script» — последний ответ сохраняется как Script.
	  • Ключ/модель/история сохраняются между запусками Studio.

	УСТАНОВКА:
	  1. Запустите прокси: python deepseek_proxy.py
	  2. Studio: File → Experience Settings → Security → Allow HTTP Requests = ON
	  3. Plugins → Manage Plugins → Install Plugin → выберите этот файл
	  4. Тулбар → «AI Agent» → окно. Пишите задачу — агент делает сам.
--]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- ================= НАСТРОЙКИ =================
local PROXY_URL = "http://localhost:8080/v1/chat/completions"
local DEFAULT_MODEL = "deepseek-chat"
local MAX_AGENT_STEPS = 12      -- максимум действий агента за задачу
local AGENT_TEMPERATURE = 0.2   -- агенту — точность
local CHAT_TEMPERATURE = 0.7    -- чату — свобода
-- =============================================

local SYSTEM_AGENT = [[Ты — автономный ИИ-агент внутри Roblox Studio. Выполняй задачи пользователя САМ, шаг за шагом, инструментами.

ИНСТРУМЕНТЫ. Вызов = блок ```tool с JSON внутри (можно несколько блоков в одном ответе):
{"tool":"get_tree"}
{"tool":"read_script","path":"ServerScriptService/MyScript"}
{"tool":"write_script","path":"ServerScriptService/MyScript","source":"print(1)"}
{"tool":"create_instance","className":"Part","name":"MyPart","parent":"Workspace","properties":{"Position":{"Vector3":[0,10,0]},"Size":{"Vector3":[4,1,4]},"Anchored":true,"Color":{"Color3":[255,0,0]},"Material":{"Enum":["Material","Neon"]}}}
{"tool":"delete_instance","path":"Workspace/MyPart"}
{"tool":"set_property","path":"Workspace/MyPart","property":"Position","value":{"Vector3":[5,10,5]}}
{"tool":"find_instances","name":"Door"}

ПРАВИЛА:
1. СНАЧАЛА осмотрись (get_tree / find_instances / read_script), потом действуй.
2. После каждого вызова получишь РЕЗУЛЬТАТ — учитывай его в следующем шаге.
3. Задача выполнена → ответь БЕЗ блоков tool, коротко: что сделано.
4. Код Luau — рабочий, без типизации. Скрипты — серверные Script.
5. Пути: "ServerScriptService/Имя", "Workspace/Папка/Объект".]]

local SYSTEM_CHAT = "Ты — дружелюбный ассистент по Roblox Studio и Luau. Отвечай кратко и по делу. Если просят скрипт — давай чистый код Luau в блоке ```lua."

local toolbar = plugin:CreateToolbar("DeepSeek AI Agent")
local toggleBtn = toolbar:CreateButton(
	"AI Agent",
	"Открыть/закрыть окно ИИ-агента",
	"rbxasset://textures/ui/common/robux.png"
)

-- ============================================================
-- Настройки
-- ============================================================

local SETTINGS_KEY = "DeepSeekAgentSettingsV2"
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
	"DeepSeekAIAgentV2",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 520, 640, 380, 440)
)
dockGui.Title = "DeepSeek AI Agent — Roblox Studio"

local root = make("Frame", {
	Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(22, 22, 26), BorderSizePixel = 0,
}, dockGui)

-- Верхняя панель: модель + режим
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

-- Галочка «Только чат» (выключает режим агента)
local agentMode = settings.agentMode ~= false
local modeCheck = make("TextButton", {
	Size = UDim2.fromOffset(150, 22), Position = UDim2.new(1, -104, 0.5, -11),
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

-- Нижняя панель ВВОДА (якорь к низу окна, тянется при ресайзе)
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

-- Панель быстрых действий (над полем ввода)
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

-- Лента сообщений (растягивается между статусом и панелями снизу)
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

-- ПАНЕЛЬ ВВОДА УДАЛЕНА ОТСЮДА (перенесена выше с исправленным позиционированием)

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
-- Инструменты агента
-- ============================================================

local function findByPath(path)
	local current = game
	for name in string.gmatch(path or "", "[^/]+") do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end
	return current
end

local function toPropertyValue(value)
	if type(value) ~= "table" then return value end
	if value.Vector3 then
		local v = value.Vector3
		return Vector3.new(tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0)
	end
	if value.Color3 then
		local c = value.Color3
		local a, b, d = tonumber(c[1]) or 0, tonumber(c[2]) or 0, tonumber(c[3]) or 0
		if a > 1 or b > 1 or d > 1 then return Color3.fromRGB(a, b, d) end
		return Color3.new(a, b, d)
	end
	if value.UDim2 then
		local u = value.UDim2
		return UDim2.new(tonumber(u[1]) or 0, tonumber(u[2]) or 0, tonumber(u[3]) or 0, tonumber(u[4]) or 0)
	end
	if value.NumberSequence then
		local pts = {}
		for _, p in ipairs(value.NumberSequence) do
			pts[#pts + 1] = NumberSequenceKeypoint.new(tonumber(p[1]) or 0, tonumber(p[2]) or 0)
		end
		return NumberSequence.new(pts)
	end
	if value.Enum then
		local ok, val = pcall(function() return Enum[value.Enum[1]][value.Enum[2]] end)
		if ok then return val end
		return nil
	end
	return value
end

local function commitRecording(recording, ok)
	if recording then
		ChangeHistoryService:FinishRecording(recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
end

local tools = {}

tools.get_tree = function()
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

tools.read_script = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Не найден: " .. tostring(args.path) } end
	if not inst:IsA("LuaSourceContainer") then
		return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
	end
	return { ok = true, source = inst.Source }
end

tools.write_script = function(args)
	if type(args.source) ~= "string" or args.source == "" then
		return { error = "Пустой source" }
	end
	local inst = findByPath(args.path)
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: write_script")
	if inst then
		if not inst:IsA("LuaSourceContainer") then
			commitRecording(recording, false)
			return { error = inst.Name .. " — не скрипт (" .. inst.ClassName .. ")" }
		end
		inst.Source = args.source
		commitRecording(recording, true)
		return { ok = true, action = "updated", path = args.path }
	end
	local parts = {}
	for name in string.gmatch(args.path or "", "[^/]+") do parts[#parts + 1] = name end
	if #parts == 0 then
		commitRecording(recording, false)
		return { error = "Пустой путь" }
	end
	local name = table.remove(parts)
	local parent = ServerScriptService
	if #parts > 0 then
		parent = findByPath(table.concat(parts, "/")) or ServerScriptService
	end
	local okNew, newScript = pcall(function()
		local s = Instance.new("Script")
		s.Name = name
		s.Source = args.source
		s.Parent = parent
		return s
	end)
	if not okNew then
		commitRecording(recording, false)
		return { error = "Не удалось создать Script: " .. tostring(newScript) }
	end
	commitRecording(recording, true)
	return { ok = true, action = "created", path = args.path }
end

tools.create_instance = function(args)
	local ok, inst = pcall(function() return Instance.new(args.className) end)
	if not ok then return { error = "Плохой класс: " .. tostring(args.className) } end
	inst.Name = args.name or args.className
	local propErrors = {}
	for prop, value in pairs(args.properties or {}) do
		local okVal, val = pcall(toPropertyValue, value)
		if okVal and val ~= nil then
			if not pcall(function() inst[prop] = val end) then
				propErrors[#propErrors + 1] = tostring(prop)
			end
		else
			propErrors[#propErrors + 1] = tostring(prop)
		end
	end
	local parent = findByPath(args.parent or "Workspace") or Workspace
	inst.Parent = parent
	local result = { ok = true, created = inst.Name, class = inst.ClassName }
	if #propErrors > 0 then
		result.warning = "Не заданы свойства: " .. table.concat(propErrors, ", ")
	end
	return result
end

tools.delete_instance = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Не найден: " .. tostring(args.path) } end
	if inst:IsA("ServerScriptService") or inst:IsA("Workspace") then
		return { error = "Нельзя удалять сервисы" }
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Agent: delete")
	inst:Destroy()
	commitRecording(recording, true)
	return { ok = true, deleted = args.path }
end

tools.set_property = function(args)
	local inst = findByPath(args.path)
	if not inst then return { error = "Не найден: " .. tostring(args.path) } end
	local okVal, val = pcall(toPropertyValue, args.value)
	if not okVal or val == nil then return { error = "Некорректное значение" } end
	if not pcall(function() inst[args.property] = val end) then
		return { error = "Свойство " .. tostring(args.property) .. " не применимо к " .. inst.ClassName }
	end
	return { ok = true, set = tostring(args.path) .. "." .. tostring(args.property) }
end

tools.find_instances = function(args)
	local found = {}
	local target = tostring(args.name or ""):lower()
	if target == "" then return { error = "Пустое имя" } end
	for _, desc in ipairs(game:GetDescendants()) do
		if #found > 30 then break end
		if desc.Name:lower():find(target, 1, true) then
			found[#found + 1] = desc:GetFullName():gsub("^Game%.", "")
		end
	end
	return { ok = true, count = #found, matches = found }
end

-- ============================================================
-- Парсинг ответа модели (стойкий к кривым форматам)
-- ============================================================

local function extractToolCalls(text)
	local calls = {}
	-- 1) канонические блоки ```tool {...} ``` (и ```tool/json-варианты)
	for body in text:gmatch("```%w*%s*(%b{})%s*```") do
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
		if ok and type(decoded) == "table" and decoded.tool then
			calls[#calls + 1] = decoded
		end
	end
	if #calls > 0 then return calls end
	-- 2) голый JSON с "tool" прямо в тексте
	for body in text:gmatch("(%b{})") do
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
		if ok and type(decoded) == "table" and decoded.tool then
			calls[#calls + 1] = decoded
		end
	end
	return calls
end

local function stripToolBlocks(text)
	return (text
		:gsub("```%w*%s*%b{}%s*```", "")
		:gsub("```tool%s*(.-)```", "")
		:gsub("\n\n\n+", "\n\n")
		:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Убирает markdown-обёртку кода
local function stripCodeFence(source)
	local body = source:match("```%w*%s*(.-)```")
	if body and #body > 0 then return body end
	return source:gsub("```%w*", ""):gsub("```", "")
end

-- ============================================================
-- Запрос к прокси
-- ============================================================

local function callProxy(messages, temperature)
	local response = HttpService:RequestAsync({
		Url = PROXY_URL, Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer any-key", -- ключ не используется: прокси локальный
		},
		Body = HttpService:JSONEncode({
			model = modelBox.Text ~= "" and modelBox.Text or DEFAULT_MODEL,
			messages = messages,
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

-- Режим ЧАТА: один запрос, без инструментов
local function runChat(userText, messages)
	setBusy(true, "DeepSeek думает...")
	local ok, answer = pcall(callProxy, messages, CHAT_TEMPERATURE)
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

-- Режим АГЕНТА: цикл думает → инструмент → результат → ...
local function runAgent(userTask)
	local messages = {
		{ role = "system", content = SYSTEM_AGENT },
		{ role = "user", content = userTask },
	}

	for step = 1, MAX_AGENT_STEPS do
		setBusy(true, "Агент: шаг " .. step .. "/" .. MAX_AGENT_STEPS .. " — думаю...")

		local ok, answer = pcall(callProxy, messages, AGENT_TEMPERATURE)
		if not ok then
			addBubble("ОШИБКА", "Нет связи с прокси. Запущен ли deepseek_proxy.py?\n" .. tostring(answer), Color3.fromRGB(255, 110, 110))
			setBusy(false)
			return
		end

		local visible = stripToolBlocks(answer)
		if visible ~= "" then
			addBubble("Агент · шаг " .. step, visible, Color3.fromRGB(120, 255, 170))
		end

		local calls = extractToolCalls(answer)
		if #calls == 0 then
			history = messages
			settings.history = history
			saveSettings()
			addBubble("✅ ГОТОВО", "Задача выполнена за " .. step .. " шаг(ов).", Color3.fromRGB(255, 210, 100))
			setBusy(false)
			return
		end

		local results = {}
		for i, call in ipairs(calls) do
			local handler = call.tool and tools[call.tool]
			local result
			if not handler then
				result = { error = "Неизвестный инструмент: " .. tostring(call.tool) }
			else
				local okExec, res = pcall(handler, call)
				result = okExec and res or { error = tostring(res) }
			end
			addBubble("🔧 " .. tostring(call.tool) .. " #" .. i,
				HttpService:JSONEncode(result):sub(1, 500), Color3.fromRGB(160, 160, 255))
			results[#results + 1] = "РЕЗУЛЬТАТ " .. tostring(call.tool) .. " #" .. i .. ": " .. HttpService:JSONEncode(result)
		end

		messages[#messages + 1] = { role = "assistant", content = answer }
		messages[#messages + 1] = {
			role = "user",
			content = table.concat(results, "\n") .. "\n\nПродолжай. Если всё готово — ответь без блоков tool.",
		}
	end

	addBubble("⚠️ ЛИМИТ", "Достигнут лимит " .. MAX_AGENT_STEPS .. " шагов. Напишите «продолжай», чтобы агент продолжил.", Color3.fromRGB(255, 160, 100))
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
