--!strict
--[[
	DeepSeekClient.lua — ModuleScript для Roblox Studio.

	Позволяет скриптам в Studio обращаться к локальному прокси
	(deepseek_proxy.py, http://localhost:8080) как к OpenAI API.

	УСТАНОВКА:
	  1. Поместите этот ModuleScript в ServerScriptService с именем "DeepSeekClient".
	  2. Включите в Studio: File → Experience Settings → Security →
	     Allow HTTP Requests = ON.

	ПРИМЕР ИСПОЛЬЗОВАНИЯ:
	  local DeepSeekClient = require(game.ServerScriptService.DeepSeekClient)
	  local client = DeepSeekClient.new("any-key")
	  print(client:Chat("Привет, как дела?"))

	ПРИМЕР С ИСТОРИЕЙ:
	  local answer = client:ChatWithHistory({
		  { role = "system", content = "Ты — помощник по Roblox Luau." },
		  { role = "user", content = "Напиши скрипт, создающий Part." },
	  })
	  print(answer)
--]]

local HttpService = game:GetService("HttpService")

local DeepSeekClient = {}
DeepSeekClient.__index = DeepSeekClient

-- URL локального прокси (deepseek_proxy.py)
local PROXY_URL = "http://localhost:8080/v1/chat/completions"

-- Модель по умолчанию (список моделей см. в deepseek_proxy.py)
local DEFAULT_MODEL = "deepseek-chat"

function DeepSeekClient.new(apiKey: string?)
	local self = setmetatable({}, DeepSeekClient)
	-- Ключ-заглушка: локальный прокси его не проверяет, но OpenAI-клиенты
	-- обычно требуют непустой Authorization
	self.apiKey = apiKey or "any-key"
	self.model = DEFAULT_MODEL
	self.temperature = 0.7
	return self
end

-- Низкоуровневый запрос к прокси. Возвращает таблицу-ответ или кидает ошибку.
function DeepSeekClient:_request(messages: {{[string]: string}}): {[string]: any}
	local body = {
		model = self.model,
		messages = messages,
		temperature = self.temperature,
	}

	local success, response = pcall(function()
		return HttpService:RequestAsync({
			Url = PROXY_URL,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. self.apiKey,
			},
			Body = HttpService:JSONEncode(body),
		})
	end)

	if not success then
		error("DeepSeekClient: HTTP-запрос не выполнен: " .. tostring(response))
	end

	if not response.Success then
		error("DeepSeekClient: прокси вернул ошибку " .. tostring(response.StatusCode)
			.. ": " .. tostring(response.Body))
	end

	local decoded, decodedData = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decoded then
		error("DeepSeekClient: не удалось распарсить JSON ответа")
	end

	-- Обработка ошибки прокси ({"error": {...}})
	if decodedData.error then
		error("DeepSeekClient: " .. tostring(
			decodedData.error.message or decodedData.error))
	end

	return decodedData
end

-- Отправить один промпт, вернуть строку-ответ DeepSeek.
function DeepSeekClient:Chat(prompt: string): string
	assert(type(prompt) == "string" and #prompt > 0, "DeepSeekClient:Chat: пустой промпт")

	local result = self:_request({
		{ role = "user", content = prompt },
	})

	local choices = result.choices
	if not choices or #choices == 0 then
		error("DeepSeekClient: пустой ответ от прокси")
	end

	local message = choices[1].message
	if not message or not message.content then
		error("DeepSeekClient: в ответе нет content")
	end

	return message.content
end

-- Отправить массив сообщений {role, content}, вернуть строку-ответ.
function DeepSeekClient:ChatWithHistory(messages: {{[string]: string}}): string
	assert(type(messages) == "table" and #messages > 0,
		"DeepSeekClient:ChatWithHistory: messages должен быть непустым массивом")
	for _, msg in ipairs(messages) do
		assert(type(msg.role) == "string" and type(msg.content) == "string",
			"DeepSeekClient:ChatWithHistory: каждое сообщение должно иметь {role, content}")
	end

	local result = self:_request(messages)

	local choices = result.choices
	if not choices or #choices == 0 then
		error("DeepSeekClient: пустой ответ от прокси")
	end

	return choices[1].message.content
end

return DeepSeekClient
