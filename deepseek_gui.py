# -*- coding: utf-8 -*-
"""
deepseek_gui.py — GUI (tkinter) для общения с DeepSeek через Яндекс Браузер.
Общение напрямую, без Roblox.

Запуск: python deepseek_gui.py
Зависимости: pip install selenium
"""

import threading
import time
import queue
import os

import tkinter as tk
from tkinter import scrolledtext, messagebox

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
# НАСТРОЙКИ (те же пути, что и в прокси)
# ============================================================

# Ссылка на существующий чат DeepSeek (вы должны быть залогинены в этом профиле!)
CHAT_URL = "https://chat.deepseek.com/a/chat/s/42a1e1eb-8621-443b-817d-fa2e541fac46"

# Путь к exe Яндекс Браузера
YANDEX_EXE = r"C:\Program Files\Yandex\YandexBrowser\Application\browser.exe"

# Профиль Яндекс Браузера. Используем ОТДЕЛЬНЫЙ профиль автоматизации (лежит
# в папке проекта), чтобы не конфликтовать с запущенным Яндекс Браузером.
# ВАЖНО: при ПЕРВОМ запуске откроется чистый браузер — один раз залогиньтесь
# в chat.deepseek.com в этом окне. Сессия сохранится в этом профиле навсегда.
# (Если хотите использовать свой основной профиль — раскомментируйте строку ниже,
#  но тогда Яндекс Браузер должен быть ПОЛНОСТЬЮ закрыт, включая фоновые процессы.)
YANDEX_PROFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "yandex_automation_profile_gui")
# YANDEX_PROFILE = r"C:\Users\developer\AppData\Local\Yandex\YandexBrowser\User Data"

# Драйвер (yandexdriver.exe) лежит рядом со скриптом.
# Если поместили в другое место — впишите здесь ПОЛНЫЙ путь, например:
# YANDEX_DRIVER = r"C:\Tools\yandexdriver.exe"
YANDEX_DRIVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "yandexdriver.exe")

STABLE_WAIT_SECONDS = 4.5   # ждать стабилизации ответа
MAX_WAIT_SECONDS = 120      # общий таймаут ожидания

INPUT_SELECTORS = [
    "textarea",
    "div[contenteditable='true']",
    "div[role='textbox']",
]

ANSWER_SELECTORS = [
    "div.markdown",
    "div[class*='markdown']",
    "div[class*='message']",
    "div[class*='response']",
]

# ============================================================


class DeepSeekBrowser:
    """Обёртка над Selenium-браузером: отправка сообщений и чтение ответов."""

    def __init__(self):
        self.driver = None
        self.lock = threading.Lock()  # только один запрос за раз

    def start(self):
        # Проверяем драйвер заранее, чтобы дать понятную ошибку
        if not os.path.isfile(YANDEX_DRIVER):
            raise FileNotFoundError(
                f"yandexdriver.exe не найден по пути: {YANDEX_DRIVER}\n"
                "Скачайте его с https://github.com/yandex/YandexDriver/releases "
                "(версия = версии вашего Яндекс Браузера) и положите рядом со скриптом, "
                "или впишите полный путь в переменную YANDEX_DRIVER в начале файла."
            )

        options = Options()
        options.binary_location = YANDEX_EXE
        options.add_argument(r"--user-data-dir=" + YANDEX_PROFILE)
        options.add_argument("--profile-directory=Default")
        options.add_argument("--no-first-run")
        options.add_argument("--no-default-browser-check")
        options.add_argument("--disable-infobars")
        options.add_argument("--remote-allow-origins=*")
        options.add_argument("--disable-features=Translate")
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        options.add_experimental_option("useAutomationExtension", False)

        service = Service(executable_path=YANDEX_DRIVER)
        self.driver = webdriver.Chrome(service=service, options=options)
        self.driver.get(CHAT_URL)
        time.sleep(5)  # даём странице полностью загрузиться

    def restart(self):
        try:
            if self.driver:
                self.driver.quit()
        except Exception:
            pass
        self.driver = None
        time.sleep(3)
        self.start()

    def _find_input(self):
        for selector in INPUT_SELECTORS:
            try:
                el = self.driver.find_element(By.CSS_SELECTOR, selector)
                if el.is_displayed():
                    return el
            except NoSuchElementException:
                continue
        raise NoSuchElementException("Не найдено поле ввода чата DeepSeek")

    def _last_answer(self):
        for selector in ANSWER_SELECTORS:
            try:
                blocks = self.driver.find_elements(By.CSS_SELECTOR, selector)
            except WebDriverException:
                continue
            for el in reversed(blocks):
                try:
                    txt = el.text.strip()
                except StaleElementReferenceException:
                    continue
                if txt:
                    return txt
        return ""

    def ask(self, prompt):
        """Отправляет prompt и ждёт стабилизации ответа. Возвращает текст ответа."""
        with self.lock:
            try:
                input_el = self._find_input()
                input_el.click()
                try:
                    input_el.send_keys(Keys.CONTROL, "a")
                    input_el.send_keys(Keys.DELETE)
                except Exception:
                    pass
                input_el.send_keys(prompt)
                time.sleep(0.3)
                input_el.send_keys(Keys.ENTER)
            except (WebDriverException, NoSuchElementException):
                self.restart()
                input_el = self._find_input()
                input_el.click()
                input_el.send_keys(prompt)
                time.sleep(0.3)
                input_el.send_keys(Keys.ENTER)

            # Ждём, пока ответ перестанет меняться
            last_text = ""
            stable_since = None
            start = time.time()
            while True:
                time.sleep(0.5)
                current = self._last_answer()
                if current and current == last_text:
                    if stable_since is None:
                        stable_since = time.time()
                    if time.time() - stable_since >= STABLE_WAIT_SECONDS:
                        return current
                else:
                    stable_since = None
                    last_text = current
                if time.time() - start > MAX_WAIT_SECONDS:
                    return last_text


class ChatGUI:
    """Главное окно чата."""

    def __init__(self, root):
        self.root = root
        root.title("DeepSeek GUI — чат через Яндекс Браузер")
        root.geometry("780x600")

        self.browser = DeepSeekBrowser()
        self.history = []  # [{role, content}]
        self.ui_queue = queue.Queue()  # сообщения из фонового потока в GUI-поток
        self.busy = False

        self._build_ui()
        root.after(100, self._process_queue)
        # Браузер запускаем в отдельном потоке, чтобы GUI не зависал
        threading.Thread(target=self._start_browser, daemon=True).start()

    # ---------- Интерфейс ----------

    def _build_ui(self):
        # История чата (только для чтения)
        self.chat_box = scrolledtext.ScrolledText(
            self.root, wrap=tk.WORD, state=tk.DISABLED, font=("Segoe UI", 11)
        )
        self.chat_box.pack(fill=tk.BOTH, expand=True, padx=8, pady=(8, 4))

        # Нижняя панель: поле ввода + кнопки
        bottom = tk.Frame(self.root)
        bottom.pack(fill=tk.X, padx=8, pady=(0, 8))

        self.input_field = tk.Entry(bottom, font=("Segoe UI", 11))
        self.input_field.pack(side=tk.LEFT, fill=tk.X, expand=True, ipady=6)
        self.input_field.bind("<Return>", lambda e: self.on_send())

        self.send_btn = tk.Button(
            bottom, text="Отправить", width=12, command=self.on_send
        )
        self.send_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.clear_btn = tk.Button(
            bottom, text="Очистить историю", width=15, command=self.on_clear
        )
        self.clear_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.status_var = tk.StringVar(value="Запуск браузера...")
        tk.Label(
            self.root, textvariable=self.status_var, anchor="w", fg="#555555"
        ).pack(fill=tk.X, padx=8, pady=(0, 4))

    def _append_chat(self, who, text):
        """Добавляет сообщение в историю (вызывается только из GUI-потока)."""
        self.chat_box.configure(state=tk.NORMAL)
        self.chat_box.insert(tk.END, f"{who}: {text}\n\n")
        self.chat_box.see(tk.END)
        self.chat_box.configure(state=tk.DISABLED)

    # ---------- Фоновые потоки ----------

    def _start_browser(self):
        try:
            self.browser.start()
            self.ui_queue.put(("status", "Браузер запущен — можно писать."))
        except Exception as e:
            self.ui_queue.put(("error", f"Не удалось запустить браузер: {e}"))

    def _worker_send(self, prompt):
        try:
            self.ui_queue.put(("status", "DeepSeek печатает..."))
            answer = self.browser.ask(prompt)
            self.ui_queue.put(("answer", answer))
        except Exception as e:
            self.ui_queue.put(("error", str(e)))

    # ---------- Обработка событий из очереди ----------

    def _process_queue(self):
        try:
            while True:
                kind, payload = self.ui_queue.get_nowait()
                if kind == "status":
                    self.status_var.set(payload)
                elif kind == "answer":
                    self.history.append({"role": "assistant", "content": payload})
                    self._append_chat("DeepSeek", payload)
                    self.busy = False
                    self.send_btn.configure(state=tk.NORMAL)
                    self.status_var.set("Готово. Можно писать.")
                elif kind == "error":
                    self._append_chat("ОШИБКА", payload)
                    self.busy = False
                    self.send_btn.configure(state=tk.NORMAL)
                    self.status_var.set("Ошибка.")
        except queue.Empty:
            pass
        self.root.after(100, self._process_queue)

    # ---------- Действия пользователя ----------

    def on_send(self):
        if self.busy:
            return
        text = self.input_field.get().strip()
        if not text:
            return
        self.busy = True
        self.send_btn.configure(state=tk.DISABLED)
        self.history.append({"role": "user", "content": text})
        self._append_chat("Вы", text)
        self.input_field.delete(0, tk.END)
        threading.Thread(target=self._worker_send, args=(text,), daemon=True).start()

    def on_clear(self):
        """Сброс истории чата (только локальной — DeepSeek продолжит свой контекст)."""
        if not messagebox.askyesno(
            "Очистить историю", "Очистить локальную историю чата?"
        ):
            return
        self.history.clear()
        self.chat_box.configure(state=tk.NORMAL)
        self.chat_box.delete("1.0", tk.END)
        self.chat_box.configure(state=tk.DISABLED)
        self.status_var.set("История очищена.")


if __name__ == "__main__":
    root = tk.Tk()
    app = ChatGUI(root)
    root.mainloop()
