--[[
	RobloxStudioAIGUI.lua — плагин для Roblox Studio: GUI-чат с DeepSeek.

	ЧТО УМЕЕТ:
	  • Окно чата (DockWidget) прямо в Studio: пишете вопрос — получаете ответ
	    DeepSeek (через локальный прокси deepseek_proxy.py на localhost:8080).
	  • Своё поле «API-ключ» (прокси его не проверяет, но всё передаёт как Bearer).
	  • Ключ и история сохраняются между запусками (настройки плагина).
	  • Кнопка «Ответ → Script»: последний ответ ИИ сохраняется как Script
	    в ServerScriptService (markdown-обёртка ```lua чистится автоматически).
	  • Кнопка «+ Part»: создаёт Part в Workspace.
	  • Кнопка «Дерево»: печатает дерево объектов в Output.

	УСТАНОВКА:
	  1. Запустите прокси: python deepseek_proxy.py
	  2. Studio: File → Experience Settings → Security → Allow HTTP Requests = ON
	  3. Plugins → Manage Plugins → Install Plugin → выберите этот файл
	  4. На тулбаре появится кнопка «AI Chat» — откроет окно чата.
	  5. В настройках (шестерёнка в окне) введите любой ключ → Сохранить.
--]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- ================= НАСТРОЙКИ =================
local PROXY_URL = "http://localhost:8080/v1/chat/completions"
local DEFAULT_MODEL = "deepseek-chat"
local REQUEST_TIMEOUT = 180 -- секунд на ответ DeepSeek (он печатает не быстро)

local SYSTEM_PROMPT = "Ты — ИИ-ассистент по Roblox Studio и языку Luau. Отвечай кратко и по делу. Когда просят скрипт — выдавай чистый код Luau без пояснений вокруг."
-- =============================================

local toolbar = plugin:CreateToolbar("DeepSeek AI Chat")
local toggleBtn = toolbar:CreateButton(
	"AI Chat",
	"Открыть/закрыть чат с DeepSeek",
	"rbxasset://textures/ui/common/robux.png"
)

-- ============================================================
-- Сохранение настроек (ключ, история) между запусками Studio
-- ============================================================

local SETTINGS_KEY = "DeepSeekAIGUISettings"
local settings = plugin:GetSetting(SETTINGS_KEY) or {
	apiKey = "any-key",
	model = DEFAULT_MODEL,
	history = nil, -- массив сообщений {role, content}; nil = только system
}

local function saveSettings()
	pcall(function()
		plugin:SetSetting(SETTINGS_KEY, settings)
	end)
end

-- История чата: всегда начинается с system-промпта
local messages = settings.history or { { role = "system", content = SYSTEM_PROMPT } }
local lastAnswer = "" -- последний ответ ИИ (для «Ответ → Script»)

-- ============================================================
-- Построение GUI
-- ============================================================

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local dockGui = plugin:CreateDockWidgetPluginGui(
	"DeepSeekAIChat",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 460, 560, 320, 380)
)
dockGui.Title = "DeepSeek AI Chat"

-- Корневой фрейм
local root = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(24, 24, 28),
	BorderSizePixel = 0,
}, dockGui)

-- Верхняя панель: настройки
local topBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = Color3.fromRGB(32, 32, 38),
	BorderSizePixel = 0,
}, root)

make("TextLabel", {
	Size = UDim2.fromOffset(40, 34),
	BackgroundTransparency = 1,
	Text = "Ключ:",
	TextColor3 = Color3.fromRGB(200, 200, 200),
	Font = Enum.Font.Gotham,
	TextSize = 13,
}, topBar)

local keyBox = make("TextBox", {
	Size = UDim2.new(1, -220, 1, -10),
	Position = UDim2.fromOffset(44, 5),
	BackgroundColor3 = Color3.fromRGB(18, 18, 22),
	TextColor3 = Color3.fromRGB(230, 230, 230),
	Text = settings.apiKey or "any-key",
	PlaceholderText = "API-ключ (любой)",
	ClearTextOnFocus = false,
	Font = Enum.Font.Code,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, keyBox)

local saveKeyBtn = make("TextButton", {
	Size = UDim2.fromOffset(58, 24),
	Position = UDim2.new(1, -170, 0.5, -12),
	BackgroundColor3 = Color3.fromRGB(0, 120, 90),
	Text = "Сохранить",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, saveKeyBtn)

local modelBox = make("TextBox", {
	Size = UDim2.fromOffset(100, 24),
	Position = UDim2.new(1, -106, 0.5, -12),
	BackgroundColor3 = Color3.fromRGB(18, 18, 22),
	TextColor3 = Color3.fromRGB(230, 230, 230),
	Text = settings.model or DEFAULT_MODEL,
	PlaceholderText = "model",
	ClearTextOnFocus = false,
	Font = Enum.Font.Code,
	TextSize = 13,
}, topBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, modelBox)

-- Панель действий Studio
local actionsBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	Position = UDim2.fromOffset(0, 34),
	BackgroundColor3 = Color3.fromRGB(28, 28, 34),
	BorderSizePixel = 0,
}, root)

local function actionButton(text, order)
	return make("TextButton", {
		Size = UDim2.fromOffset(128, 24),
		Position = UDim2.fromOffset(6 + (order - 1) * 134, 5),
		BackgroundColor3 = Color3.fromRGB(50, 50, 60),
		Text = text,
		TextColor3 = Color3.fromRGB(240, 240, 240),
		Font = Enum.Font.Gotham,
		TextSize = 12,
	}, actionsBar)
end

local toScriptBtn = actionButton("Ответ → Script", 1)
local createPartBtn = actionButton("+ Part", 2)
local treeBtn = actionButton("Дерево → Output", 3)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, toScriptBtn)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, createPartBtn)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, treeBtn)

-- Лента сообщений
local scroll = make("ScrollingFrame", {
	Size = UDim2.new(1, -12, 1, -34 - 34 - 54),
	Position = UDim2.fromOffset(6, 72),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, root)
local listLayout = make("UIListLayout", {
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, scroll)

local msgOrder = 0

local function addBubble(who, text, color)
	msgOrder += 1
	local bubble = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(36, 36, 44),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = msgOrder,
	}, scroll)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 18),
		Position = UDim2.fromOffset(8, 4),
		BackgroundTransparency = 1,
		Text = who,
		TextColor3 = color,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, bubble)
	make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.fromOffset(8, 22),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Color3.fromRGB(225, 225, 225),
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, bubble)
	scroll.CanvasPosition = Vector2.new(0, 1e9) -- прокрутка вниз
end

-- Нижняя панель: ввод
local inputBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 50),
	Position = UDim2.new(1, 0, 1, -50),
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = Color3.fromRGB(32, 32, 38),
	BorderSizePixel = 0,
}, root)

local inputBox = make("TextBox", {
	Size = UDim2.new(1, -110, 1, -12),
	Position = UDim2.fromOffset(6, 6),
	BackgroundColor3 = Color3.fromRGB(18, 18, 22),
	TextColor3 = Color3.fromRGB(235, 235, 235),
	PlaceholderText = "Спросите DeepSeek... (Enter — отправить)",
	TextWrapped = true,
	ClearTextOnFocus = false,
	Font = Enum.Font.Gotham,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, inputBox)

local sendBtn = make("TextButton", {
	Size = UDim2.fromOffset(92, 38),
	Position = UDim2.new(1, -98, 0.5, -19),
	BackgroundColor3 = Color3.fromRGB(0, 120, 90),
	Text = "Отправить",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextSize = 13,
}, inputBar)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, sendBtn)

-- Восстанавливаем прошлую историю в ленте
do
	for _, m in ipairs(messages) do
		if m.role == "user" then
			addBubble("Вы", m.content, Color3.fromRGB(120, 200, 255))
		elseif m.role == "assistant" then
			addBubble("DeepSeek", m.content, Color3.fromRGB(120, 255, 170))
		end
	end
end

-- ============================================================
-- Логика чата
-- ============================================================

local busy = false

-- Убирает markdown-обёртку ```lua ... ``` из ответа ИИ
local function stripCodeFence(source)
	local s = source
	local body = s:match("```%w*%s*(.-)```")
	if body and #body > 0 then
		s = body
	else
		s = s:gsub("```%w*", ""):gsub("```", "")
	end
	return s
end

local function setBusy(b)
	busy = b
	sendBtn.Text = b and "..." or "Отправить"
	sendBtn.AutoButtonColor = not b
end

local function sendChat()
	if busy then return end
	local text = inputBox.Text
	if text == "" then return end
	setBusy(true)
	inputBox.Text = ""

	messages[#messages + 1] = { role = "user", content = text }
	addBubble("Вы", text, Color3.fromRGB(120, 200, 255))

	task.spawn(function()
		local ok, result = pcall(function()
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
					temperature = 0.7,
				}),
			})
			if not response.Success then
				error("HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.Body):sub(1, 300))
			end
			return HttpService:JSONDecode(response.Body)
		end)

		if not ok then
			addBubble("ОШИБКА", "Проверьте: запущен ли deepseek_proxy.py и Allow HTTP Requests = ON.\n" .. tostring(result), Color3.fromRGB(255, 110, 110))
			setBusy(false)
			return
		end

		local content
		if type(result) == "table" and result.choices and result.choices[1] then
			content = result.choices[1].message.content
		elseif type(result) == "table" and result.error then
			content = "Ошибка прокси: " .. tostring(result.error.message or result.error)
		else
			content = "Неизвестный ответ: " .. tostring(result):sub(1, 300)
		end

		lastAnswer = content or ""
		messages[#messages + 1] = { role = "assistant", content = lastAnswer }
		settings.history = messages
		saveSettings()
		addBubble("DeepSeek", lastAnswer, Color3.fromRGB(120, 255, 170))
		setBusy(false)
	end)
end

-- ============================================================
-- Действия Studio
-- ============================================================

-- Последний ответ → новый Script в ServerScriptService
toScriptBtn.MouseButton1Click:Connect(function()
	if lastAnswer == "" then
		addBubble("СИСТЕМА", "Сначала получите ответ от DeepSeek.", Color3.fromRGB(255, 200, 100))
		return
	end
	local source = stripCodeFence(lastAnswer)
	local name = "AIScript"
	local i = 1
	while ServerScriptService:FindFirstChild(name) do
		i += 1
		name = "AIScript" .. i
	end
	local recording = ChangeHistoryService:TryBeginRecording("AI Chat: создать Script")
	local scriptInst = Instance.new("Script")
	scriptInst.Name = name
	scriptInst.Source = source
	scriptInst.Parent = ServerScriptService
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	addBubble("СИСТЕМА", "Скрипт сохранён: ServerScriptService/" .. name, Color3.fromRGB(255, 200, 100))
end)

-- Создать Part
createPartBtn.MouseButton1Click:Connect(function()
	local recording = ChangeHistoryService:TryBeginRecording("AI Chat: создать Part")
	local part = Instance.new("Part")
	part.Name = "AIPart"
	part.Size = Vector3.new(4, 1, 4)
	part.Position = Vector3.new(0, 10, 0)
	part.Anchored = true
	part.Parent = Workspace
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	addBubble("СИСТЕМА", "Part создан в Workspace (0, 10, 0)", Color3.fromRGB(255, 200, 100))
end)

-- Печать дерева объектов в Output
treeBtn.MouseButton1Click:Connect(function()
	local lines = {}
	local function walk(inst, depth)
		if depth > 4 then return end
		lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]"
		for _, child in ipairs(inst:GetChildren()) do
			walk(child, depth + 1)
		end
	end
	for _, svc in ipairs({Workspace, ServerScriptService, game:GetService("StarterGui"), game:GetService("ReplicatedStorage")}) do
		walk(svc, 0)
	end
	print("=== ДЕРЕВО ОБЪЕКТОВ ===\n" .. table.concat(lines, "\n"))
	addBubble("СИСТЕМА", "Дерево напечатано в Output (View → Output)", Color3.fromRGB(255, 200, 100))
end)

-- ============================================================
-- События
-- ============================================================

sendBtn.MouseButton1Click:Connect(sendChat)
inputBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		sendChat()
	end
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

plugin.Unloading:Connect(function()
	settings.history = messages
	saveSettings()
end)
