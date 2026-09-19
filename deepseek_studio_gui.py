# -*- coding: utf-8 -*-
"""
deepseek_studio_gui.py — GUI-чат с DeepSeek + управление Roblox Studio.

Чат идёт через прокси deepseek_proxy.py (localhost:8080, OpenAI-формат),
работа с объектами Studio — через MCP-сервер robomcp.py (localhost:3001)
и плагин RobloxStudioPlugin.lua.

ПЕРЕД ЗАПУСКОМ должны работать:
  1. python deepseek_proxy.py   (чат)
  2. python robomcp.py          (файлы Studio, нужен плагин в Studio)

Запуск: python deepseek_studio_gui.py
Зависимости: pip install requests  (tkinter и selenium НЕ нужны)
"""

import threading
import queue
import json
import tkinter as tk
from tkinter import scrolledtext, messagebox, simpledialog

import requests

# ============================================================
# НАСТРОЙКИ
# ============================================================

PROXY_URL = "http://localhost:8080/v1/chat/completions"   # чат через прокси
MCP_URL = "http://localhost:3001"                          # MCP-сервер Studio
MODEL = "deepseek-chat"
API_KEY = "any-key"  # локальный прокси ключ не проверяет

# Системный промпт: настраивает DeepSeek как ассистента по Roblox Luau
SYSTEM_PROMPT = (
    "Ты — ИИ-ассистент по Roblox Studio и языку Luau. "
    "Когда тебя просят написать скрипт, выдавай ТОЛЬКО чистый код Luau "
    "без пояснений вокруг, чтобы его можно было сразу сохранить в Script."
)

# ============================================================


class StudioGUI:
    """Главное окно: чат + кнопки работы с Roblox Studio."""

    def __init__(self, root):
        self.root = root
        root.title("DeepSeek GUI — чат + Roblox Studio")
        root.geometry("860x680")

        self.history = [{"role": "system", "content": SYSTEM_PROMPT}]
        self.ui_queue = queue.Queue()
        self.busy = False
        self.last_answer = ""  # последний ответ DeepSeek (для «сохранить в Studio»)

        self._build_ui()
        root.after(100, self._process_queue)

        # Проверка доступности серверов при старте (в фоне)
        threading.Thread(target=self._check_servers, daemon=True).start()

    # ---------- Интерфейс ----------

    def _build_ui(self):
        # Верхняя панель: кнопки Roblox Studio
        tools = tk.Frame(self.root)
        tools.pack(fill=tk.X, padx=8, pady=(8, 2))

        tk.Button(tools, text="📁 Дерево объектов", command=self.on_tree,
                  width=16).pack(side=tk.LEFT)
        tk.Button(tools, text="📖 Читать скрипт", command=self.on_read,
                  width=14).pack(side=tk.LEFT, padx=(6, 0))
        tk.Button(tools, text="💾 Ответ → Studio", command=self.on_save_to_studio,
                  width=15).pack(side=tk.LEFT, padx=(6, 0))
        tk.Button(tools, text="➕ Создать объект", command=self.on_create,
                  width=15).pack(side=tk.LEFT, padx=(6, 0))
        tk.Button(tools, text="🗑 Удалить объект", command=self.on_delete,
                  width=15).pack(side=tk.LEFT, padx=(6, 0))

        # История чата
        self.chat_box = scrolledtext.ScrolledText(
            self.root, wrap=tk.WORD, state=tk.DISABLED, font=("Segoe UI", 11)
        )
        self.chat_box.pack(fill=tk.BOTH, expand=True, padx=8, pady=(4, 4))

        # Нижняя панель: поле ввода + кнопки
        bottom = tk.Frame(self.root)
        bottom.pack(fill=tk.X, padx=8, pady=(0, 8))

        self.input_field = tk.Entry(bottom, font=("Segoe UI", 11))
        self.input_field.pack(side=tk.LEFT, fill=tk.X, expand=True, ipady=6)
        self.input_field.bind("<Return>", lambda e: self.on_send())

        self.send_btn = tk.Button(bottom, text="Отправить", width=12,
                                  command=self.on_send)
        self.send_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.clear_btn = tk.Button(bottom, text="Очистить", width=10,
                                   command=self.on_clear)
        self.clear_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.status_var = tk.StringVar(value="Проверка серверов...")
        tk.Label(self.root, textvariable=self.status_var, anchor="w",
                 fg="#555555").pack(fill=tk.X, padx=8, pady=(0, 4))

    def _append_chat(self, who, text):
        self.chat_box.configure(state=tk.NORMAL)
        self.chat_box.insert(tk.END, f"{who}: {text}\n\n")
        self.chat_box.see(tk.END)
        self.chat_box.configure(state=tk.DISABLED)

    # ---------- Очередь сообщений из фоновых потоков ----------

    def _process_queue(self):
        try:
            while True:
                kind, payload = self.ui_queue.get_nowait()
                if kind == "status":
                    self.status_var.set(payload)
                elif kind == "chat":
                    who, text = payload
                    self._append_chat(who, text)
                elif kind == "answer":
                    self.last_answer = payload
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

    # ---------- Проверка серверов ----------

    def _check_servers(self):
        msgs = []
        try:
            requests.get("http://localhost:8080/health", timeout=3)
            msgs.append("прокси: OK")
        except Exception:
            msgs.append("прокси: НЕ ЗАПУЩЕН (python deepseek_proxy.py)")
        try:
            requests.get(MCP_URL + "/health", timeout=3)
            msgs.append("MCP: OK")
        except Exception:
            msgs.append("MCP: не запущен (python robomcp.py)")
        self.ui_queue.put(("status", " | ".join(msgs)))

    # ---------- Чат ----------

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
        self.status_var.set("DeepSeek думает...")
        threading.Thread(target=self._worker_chat, daemon=True).start()

    def _worker_chat(self):
        try:
            resp = requests.post(
                PROXY_URL,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer " + API_KEY,
                },
                json={"model": MODEL, "messages": self.history, "temperature": 0.7},
                timeout=180,
            )
            data = resp.json()
            if resp.status_code != 200:
                raise RuntimeError(data.get("error", {}).get("message", resp.text))
            answer = data["choices"][0]["message"]["content"]
            self.ui_queue.put(("answer", answer))
        except Exception as e:
            self.ui_queue.put(("error", f"Чат: {e}"))

    def on_clear(self):
        self.history = [{"role": "system", "content": SYSTEM_PROMPT}]
        self.chat_box.configure(state=tk.NORMAL)
        self.chat_box.delete("1.0", tk.END)
        self.chat_box.configure(state=tk.DISABLED)
        self.status_var.set("История очищена.")

    # ---------- Кнопки Roblox Studio (MCP) ----------

    def _mcp_get(self, path, params=None):
        r = requests.get(MCP_URL + path, params=params, timeout=30)
        return r.json()

    def _mcp_post(self, path, body):
        r = requests.post(MCP_URL + path, json=body, timeout=30)
        return r.json()

    def on_tree(self):
        """Показать дерево объектов Studio."""
        def worker():
            try:
                data = self._mcp_get("/api/file-tree")
                if "error" in data:
                    raise RuntimeError(data["error"])
                lines = []
                def walk(node, depth):
                    lines.append("  " * depth + f"{node['name']} [{node['className']}]")
                    for ch in node.get("children", []):
                        walk(ch, depth + 1)
                walk(data["tree"], 0)
                self.ui_queue.put(("chat", ("📁 ДЕРЕВО ОБЪЕКТОВ", "\n".join(lines[:200]))))
            except Exception as e:
                self.ui_queue.put(("error", f"Дерево: {e}"))
        threading.Thread(target=worker, daemon=True).start()

    def on_read(self):
        """Прочитать скрипт по пути."""
        path = simpledialog.askstring(
            "Читать скрипт", "Путь к скрипту:",
            parent=self.root)
        if not path:
            return

        def worker():
            try:
                data = self._mcp_get("/api/script", params={"path": path})
                if "error" in data:
                    raise RuntimeError(data["error"])
                self.ui_queue.put(("chat", (f"📖 КОД {path}", data.get("source", ""))))
            except Exception as e:
                self.ui_queue.put(("error", f"Чтение: {e}"))
        threading.Thread(target=worker, daemon=True).start()

    def on_save_to_studio(self):
        """Сохранить последний ответ DeepSeek как скрипт в Studio."""
        if not self.last_answer:
            messagebox.showinfo("Нет ответа", "Сначала получите ответ от DeepSeek.")
            return
        path = simpledialog.askstring(
            "Сохранить в Studio",
            "Путь нового скрипта (например ServerScriptService/AIScript):",
            parent=self.root)
        if not path:
            return

        source = self.last_answer
        # Отчищаем возможную markdown-обёртку ```lua ... ```
        if source.strip().startswith("```"):
            lines = [l for l in source.strip().splitlines()
                     if not l.strip().startswith("```")]
            source = "\n".join(lines)

        def worker():
            try:
                data = self._mcp_post("/api/script", {"path": path, "source": source})
                if "error" in data:
                    raise RuntimeError(data["error"])
                self.ui_queue.put(("chat", ("💾 СТУДИЯ", f"Код сохранён в {path}")))
            except Exception as e:
                self.ui_queue.put(("error", f"Сохранение: {e}"))
        threading.Thread(target=worker, daemon=True).start()

    def on_create(self):
        """Создать объект в Studio."""
        class_name = simpledialog.askstring(
            "Создать объект", "Класс (Part, Script, Folder, Model...):",
            parent=self.root)
        if not class_name:
            return
        name = simpledialog.askstring("Создать объект", "Имя объекта:",
                                      parent=self.root)
        if not name:
            return
        parent = simpledialog.askstring(
            "Создать объект", "Родитель (по умолчанию Workspace):",
            initialvalue="Workspace", parent=self.root) or "Workspace"

        def worker():
            try:
                data = self._mcp_post("/api/instance", {
                    "className": class_name, "name": name, "parent": parent})
                if "error" in data:
                    raise RuntimeError(data["error"])
                self.ui_queue.put(("chat", ("➕ СТУДИЯ",
                    f"Создан {class_name} '{name}' в {parent} → {data.get('path', '')}")))
            except Exception as e:
                self.ui_queue.put(("error", f"Создание: {e}"))
        threading.Thread(target=worker, daemon=True).start()

    def on_delete(self):
        """Удалить объект в Studio."""
        path = simpledialog.askstring(
            "Удалить объект", "Путь объекта (например Workspace/MyPart):",
            parent=self.root)
        if not path:
            return

        def worker():
            try:
                r = requests.delete(MCP_URL + "/api/instance",
                                    params={"path": path}, timeout=30)
                data = r.json()
                if "error" in data:
                    raise RuntimeError(data["error"])
                self.ui_queue.put(("chat", ("🗑 СТУДИЯ", f"Удалён объект {path}")))
            except Exception as e:
                self.ui_queue.put(("error", f"Удаление: {e}"))
        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    root = tk.Tk()
    app = StudioGUI(root)
    root.mainloop()
