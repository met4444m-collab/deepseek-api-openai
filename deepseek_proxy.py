# -*- coding: utf-8 -*-
"""
deepseek_proxy.py — OpenAI-совместимый прокси к чату DeepSeek (chat.deepseek.com)
через Selenium + Яндекс Браузер.

Запуск: python deepseek_proxy.py
Зависимости: pip install flask selenium
"""

import time
import threading
import uuid

from flask import Flask, request, jsonify
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.common.exceptions import (
    WebDriverException,
    NoSuchElementException,
    StaleElementReferenceException,
)

# ============================================================
# НАСТРОЙКИ (захардкожены — меняйте под свою систему)
# ============================================================

# Ссылка на существующий чат DeepSeek (вы должны быть залогинены в этом профиле!)
# Подставьте свою ссылку вместо этой.
CHAT_URL = "https://chat.deepseek.com/a/chat/s/42a1e1eb-8621-443b-817d-fa2e541fac46"

# Путь к exe Яндекс Браузера
YANDEX_EXE = r"C:\Program Files\Yandex\YandexBrowser\Application\browser.exe"

# Профиль Яндекс Браузера (в нём хранится логин-сессия DeepSeek)
YANDEX_PROFILE = r"C:\Users\developer\AppData\Local\Yandex\YandexBrowser\User Data"

# Драйвер (yandexdriver.exe) лежит рядом со скриптом
YANDEX_DRIVER = "yandexdriver.exe"

# Порт прокси-сервера
PROXY_PORT = 8080

# Сколько секунд ждать стабилизации ответа (ответ перестал меняться)
STABLE_WAIT_SECONDS = 4.5

# Сколько секунд максимально ждать ответ (защита от зависания)
MAX_WAIT_SECONDS = 120

# Селекторы поля ввода (пробуются по порядку)
INPUT_SELECTORS = [
    "textarea",
    "div[contenteditable='true']",
    "div[role='textbox']",
]

# Селекторы блоков ответа (пробуются по порядку)
ANSWER_SELECTORS = [
    "div.markdown",
    "div[class*='markdown']",
    "div[class*='message']",
    "div[class*='response']",
]

# ============================================================

app = Flask(__name__)

# Блокировка: только один запрос к браузеру за раз
browser_lock = threading.Lock()

# Глобальная ссылка на драйвер
driver = None


def create_driver():
    """Создаёт и возвращает WebDriver для Яндекс Браузера с профилем пользователя."""
    options = Options()
    options.binary_location = YANDEX_EXE
    # Используем профиль пользователя — там уже есть авторизация в DeepSeek
    options.add_argument(r"--user-data-dir=" + YANDEX_PROFILE)
    options.add_argument("--profile-directory=Default")
    options.add_argument("--no-first-run")
    options.add_argument("--no-default-browser-check")
    options.add_argument("--disable-infobars")
    options.add_argument("--start-maximized")
    # Не добавляем --headless: чат DeepSeek работает только в видимом окне
    options.add_experimental_option("excludeSwitches", ["enable-automation"])
    options.add_experimental_option("useAutomationExtension", False)

    service = Service(executable_path=YANDEX_DRIVER)
    drv = webdriver.Chrome(service=service, options=options)
    return drv


def start_browser():
    """Запускает браузер один раз и открывает чат DeepSeek."""
    global driver
    driver = create_driver()
    driver.get(CHAT_URL)
    time.sleep(5)  # даём странице полностью загрузиться
    print("[PROXY] Браузер запущен, чат DeepSeek открыт.")


def restart_browser():
    """Перезапускает браузер после падения."""
    global driver
    print("[PROXY] Перезапуск браузера...")
    try:
        if driver:
            driver.quit()
    except Exception:
        pass
    driver = None
    time.sleep(3)
    start_browser()


def find_input_element():
    """Ищет поле ввода чата по списку селекторов."""
    for selector in INPUT_SELECTORS:
        try:
            el = driver.find_element(By.CSS_SELECTOR, selector)
            if el.is_displayed():
                return el
        except NoSuchElementException:
            continue
    raise NoSuchElementException("Не найдено поле ввода чата DeepSeek")


def send_message(text):
    """Отправляет сообщение в чат DeepSeek."""
    input_el = find_input_element()
    input_el.click()
    # Очищаем поле (на случай остатков текста)
    try:
        input_el.send_keys(Keys.CONTROL, "a")
        input_el.send_keys(Keys.DELETE)
    except Exception:
        pass
    input_el.send_keys(text)
    time.sleep(0.3)
    input_el.send_keys(Keys.ENTER)


def get_last_answer():
    """Возвращает последний непустой блок ответа или пустую строку."""
    for selector in ANSWER_SELECTORS:
        try:
            blocks = driver.find_elements(By.CSS_SELECTOR, selector)
        except WebDriverException:
            continue
        # Идём с конца и берём первый непустой блок
        for el in reversed(blocks):
            try:
                txt = el.text.strip()
            except StaleElementReferenceException:
                continue
            if txt:
                return txt
    return ""


def wait_for_stable_answer():
    """
    Ждёт, пока ответ перестанет меняться в течение STABLE_WAIT_SECONDS.
    Возвращает финальный текст ответа.
    """
    last_text = ""
    stable_since = None
    start = time.time()

    while True:
        time.sleep(0.5)
        current = get_last_answer()

        if current and current == last_text:
            if stable_since is None:
                stable_since = time.time()
            if time.time() - stable_since >= STABLE_WAIT_SECONDS:
                return current
        else:
            # Текст изменился (или стал непустым) — сбрасываем таймер стабильности
            stable_since = None
            last_text = current

        # Общий таймаут
        if time.time() - start > MAX_WAIT_SECONDS:
            print("[PROXY] Таймаут ожидания ответа — возвращаем то, что есть.")
            return last_text


def ask_deepseek(prompt):
    """Полный цикл: отправить вопрос и получить ответ. При падении — перезапуск браузера."""
    global driver
    # Браузер мог не запуститься при старте сервера — пробуем поднять его сейчас
    if driver is None:
        restart_browser()
    try:
        send_message(prompt)
        answer = wait_for_stable_answer()
        return answer
    except (WebDriverException, NoSuchElementException) as e:
        print(f"[PROXY] Ошибка браузера: {e}. Перезапускаем и пробуем ещё раз.")
        restart_browser()
        # Повторная попытка после перезапуска
        try:
            send_message(prompt)
            return wait_for_stable_answer()
        except Exception as e2:
            raise RuntimeError(f"Не удалось получить ответ после перезапуска: {e2}")


# ============================================================
# HTTP-эндпоинты (OpenAI-совместимые)
# ============================================================

MODELS = ["deepseek-chat", "deepseek-v4-flash", "deepseek-reasoner"]


@app.route("/v1/models", methods=["GET"])
def list_models():
    """Список моделей в формате OpenAI."""
    return jsonify({
        "object": "list",
        "data": [{"id": m, "object": "model", "created": 0, "owned_by": "deepseek"} for m in MODELS],
    })


@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    """
    Принимает JSON в формате OpenAI:
      {model, messages: [{role, content}, ...], temperature}
    Достаёт последнее сообщение пользователя, отправляет в DeepSeek,
    возвращает ответ в формате OpenAI.
    """
    try:
        payload = request.get_json(force=True)
    except Exception:
        return jsonify({"error": {"message": "Некорректный JSON"}}), 400

    messages = payload.get("messages") or []
    model = payload.get("model") or "deepseek-chat"

    # Берём последнее сообщение с ролью user
    user_text = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_text = msg.get("content", "")
            break
    if not user_text:
        return jsonify({"error": {"message": "Не найдено сообщение пользователя"}}), 400

    # Только один запрос к браузеру за раз
    with browser_lock:
        try:
            answer = ask_deepseek(user_text)
        except RuntimeError as e:
            return jsonify({"error": {"message": str(e)}}), 502

    return jsonify({
        "id": "chatcmpl-" + uuid.uuid4().hex[:12],
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


@app.route("/health", methods=["GET"])
def health():
    """Проверка живости прокси."""
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    # Запускаем браузер до старта сервера. Если не получилось (нет драйвера,
    # профиль занят и т.п.) — сервер всё равно поднимется и вернёт 502 на запросы,
    # чтобы можно было увидеть понятную ошибку вместо молчаливого падения.
    try:
        start_browser()
    except Exception as e:
        print(f"[PROXY] ВНИМАНИЕ: браузер не запустился при старте: {e}")
        print("[PROXY] Сервер всё равно стартует; браузер перезапустится при первом запросе.")
    print(f"[PROXY] Сервер слушает http://localhost:{PROXY_PORT}")
    # threaded=True — Flask может принимать параллельные соединения,
    # но доступ к браузеру всё равно сериализуется через browser_lock
    app.run(host="0.0.0.0", port=PROXY_PORT, threaded=True)
