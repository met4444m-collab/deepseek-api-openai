# DeepSeek → Roblox Studio: полная система

Система из 6 частей: GUI и OpenAI-совместимый прокси к чату DeepSeek через Яндекс Браузер (Selenium), Lua-клиент для Roblox Studio и MCP-сервер для доступа к файлам и объектам Studio.

```
┌──────────────┐   OpenAI API    ┌────────────────────┐   Selenium   ┌──────────────┐
│ Roblox Studio│ ──────────────► │ deepseek_proxy.py  │ ───────────► │ chat.deepseek│
│ (Luau-скрипты)│  localhost:8080 │  + deepseek_gui.py │  Яндекс      │   .com       │
└──────┬───────┘                 └────────────────────┘  Браузер     └──────────────┘
       │ localhost:3001
┌──────▼───────┐
│ robomcp.py   │  ◄──► RobloxStudioPlugin.lua (плагин в Studio)
│ (MCP-сервер) │
└──────────────┘
```

## Файлы

| Файл | Что это |
|---|---|
| `deepseek_proxy.py` | Flask-сервер (порт 8080) — OpenAI-совместимый API к чату DeepSeek |
| `deepseek_gui.py` | Tkinter GUI для общения с DeepSeek напрямую |
| `DeepSeekClient.lua` | ModuleScript для Studio — клиент к прокси |
| `robomcp.py` | MCP-сервер (порт 3001) — доступ к объектам и скриптам Studio |
| `RobloxStudioPlugin.lua` | Плагин Studio — выполняет команды MCP-сервера |
| `README.md` | Этот файл |

## 1. Установка

### 1.1. yandexdriver.exe

Скачайте с https://github.com/yandex/YandexDriver/releases драйвер, **версия которого совпадает с версией вашего Яндекс Браузера** (версию браузера смотрите в Меню → Справка → О браузере).

Положите `yandexdriver.exe` рядом со скриптами (`deepseek_proxy.py`, `deepseek_gui.py`).

### 1.2. Зависимости Python

```bash
pip install flask flask-cors selenium requests
```

### 1.3. Ссылка на чат DeepSeek

Откройте https://chat.deepseek.com в Яндекс Браузере, залогиньтесь, создайте чат и скопируйте ссылку вида `https://chat.deepseek.com/a/chat/s/XXXXXXXX`.

Вставьте её в **оба** файла — замените `ССЫЛКА` на свою:

- `deepseek_proxy.py` → строка `CHAT_URL = "https://chat.deepseek.com/a/chat/s/ССЫЛКА"`
- `deepseek_gui.py` → строка `CHAT_URL = "https://chat.deepseek.com/a/chat/s/ССЫЛКА"`

Заодно проверьте пути `YANDEX_EXE` и `YANDEX_PROFILE` (в них захардкожен пользователь `developer` — поменяйте на своего, если нужно).

## 2. Запуск

**Важно: полностью закройте Яндекс Браузер перед запуском** (проверьте трей — иначе Selenium не сможет запустить браузер с вашим профилем: профиль занят).

```bash
# 1. Прокси (обязательно)
python deepseek_proxy.py

# 2. GUI для общения с DeepSeek (по желанию)
python deepseek_gui.py

# 3. MCP-сервер (обязательно для Roblox-части)
python robomcp.py
```

Проверка прокси: откройте http://localhost:8080/health — должно вернуть `{"status": "ok"}`.

Проверка MCP: http://localhost:3001/health.

## 3. Настройка Roblox Studio

1. **HTTP-запросы**: File → Experience Settings → Security → **Allow HTTP Requests = ON**.
2. **Доступ к API**: File → Experience Settings → Security → **Enable Studio Access to API Services = ON**.
3. **Установить плагин**: Plugins → Manage Plugins → Install Plugin → выберите `RobloxStudioPlugin.lua`. После установки нажмите кнопку **RoboMCP** на тулбаре плагинов (она загорается зелёным = мост работает).
4. **Клиент**: в `ServerScriptService` создайте ModuleScript с именем `DeepSeekClient` и вставьте код из `DeepSeekClient.lua`.

## 4. Использование в скриптах

```lua
local DeepSeekClient = require(game.ServerScriptService.DeepSeekClient)
local client = DeepSeekClient.new("any-key")

-- Один вопрос
print(client:Chat("Привет, как дела?"))

-- С историей (роль system задаёт поведение)
local answer = client:ChatWithHistory({
    { role = "system", content = "Ты — ИИ-ассистент по Roblox Luau." },
    { role = "user",   content = "Напиши скрипт, создающий Part в Workspace." },
})
print(answer)
```

## 5. MCP: доступ DeepSeek к объектам Studio

`robomcp.py` даёт внешним инструментам (и DeepSeek через прокси) доступ к Studio:

| Метод | Эндпоинт | Действие |
|---|---|---|
| GET | `/api/file-tree` | Дерево объектов DataModel |
| GET | `/api/script?path=ServerScriptService/MyScript` | Прочитать код скрипта |
| POST | `/api/script` `{path, source}` | Сохранить код в скрипт |
| POST | `/api/instance` `{className, name, parent}` | Создать объект (Part, Script, Folder…) |
| DELETE | `/api/instance?path=Workspace/MyPart` | Удалить объект |

Пример через Python:

```python
import requests

# Дерево объектов
print(requests.get("http://localhost:3001/api/file-tree").json())

# Прочитать скрипт
print(requests.get("http://localhost:3001/api/script",
                   params={"path": "ServerScriptService/MyScript"}).json())

# Создать Part
requests.post("http://localhost:3001/api/instance",
              json={"className": "Part", "name": "MyPart", "parent": "Workspace"})
```

## 6. Важные замечания

- **localhost работает только в Roblox Studio** (для тестов). Для реальной игры нужен публичный сервер: VPS или туннель (ngrok), и замените `localhost` на адрес сервера в `DeepSeekClient.lua` и `RobloxStudioPlugin.lua`.
- Ответ DeepSeek определяется как «готов», когда текст ответа не меняется **4.5 секунды**. Для очень длинных ответов увеличьте `STABLE_WAIT_SECONDS` в скриптах.
- Прокси отправляет в DeepSeek **только последнее сообщение пользователя** — сам чат DeepSeek хранит контекст своей беседы. История `ChatWithHistory` нужна для формирования промпта, а не для памяти DeepSeek.
- Если браузер Selenium упал, прокси перезапустит его автоматически. Если ошибка повторяется — проверьте версию `yandexdriver.exe` (должна совпадать с версией браузера) и что профиль не занят открытым Яндекс Браузером.
- Правки скриптов через MCP записываются через `ChangeHistoryService` — работает Undo (Ctrl+Z) в Studio.
