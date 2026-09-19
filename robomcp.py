# -*- coding: utf-8 -*-
"""
robomcp.py — MCP-сервер для доступа к файлам и объектам Roblox Studio.

Работает на http://localhost:3001. Roblox Studio подключается к нему
через плагин RobloxStudioPlugin.lua (Часть 5).

Эндпоинты:
  GET    /api/file-tree          → дерево объектов Studio (через плагин)
  GET    /api/script?path=<путь> → код скрипта из Studio
  POST   /api/script             → сохранить код в скрипт в Studio
  POST   /api/instance           → создать объект (Part, Script, Folder и т.д.)
  DELETE /api/instance           → удалить объект
  GET    /api/command            → плагин забирает следующую команду
  POST   /api/response           → плагин возвращает результат команды

Зависимости: pip install flask flask-cors requests
Запуск: python robomcp.py
"""

import queue
import threading
import uuid

from flask import Flask, request, jsonify
from flask_cors import CORS

# Порт MCP-сервера (плагин в Studio ходит сюда)
MCP_PORT = 3001

# Таймаут ожидания ответа от плагина в Studio (секунды)
PLUGIN_TIMEOUT_SECONDS = 15

app = Flask(__name__)
CORS(app)  # разрешаем кросс-доменные запросы (для веб-инструментов)

# ============================================================
# Очередь команд и ответов между MCP-клиентами и плагином Studio
# ============================================================

# Очередь команд: MCP-сервер кладёт, плагин забирает
command_queue = queue.Queue()

# Словарь ожидающих ответов: command_id → {event, response}
pending_responses = {}
pending_lock = threading.Lock()


def make_command(action, **params):
    """Создаёт команду, кладёт в очередь и ждёт ответ от плагина."""
    command_id = uuid.uuid4().hex[:12]
    command = {"id": command_id, "action": action, **params}

    event = threading.Event()
    holder = {"event": event, "response": None}

    with pending_lock:
        pending_responses[command_id] = holder

    command_queue.put(command)
    print(f"[MCP] → Studio: {command}")

    if not event.wait(timeout=PLUGIN_TIMEOUT_SECONDS):
        with pending_lock:
            pending_responses.pop(command_id, None)
        return {"error": "Плагин Studio не ответил (таймаут). Запущен ли плагин?"}

    with pending_lock:
        pending_responses.pop(command_id, None)
    return holder["response"] or {"error": "Пустой ответ от плагина"}


# ============================================================
# Эндпоинты для плагина Roblox Studio
# ============================================================


@app.route("/api/command", methods=["GET"])
def get_command():
    """Плагин опрашивает эту точку: забрать следующую команду."""
    try:
        command = command_queue.get_nowait()
        return jsonify(command)
    except queue.Empty:
        return jsonify({"action": None})


@app.route("/api/response", methods=["POST"])
def post_response():
    """Плагин возвращает результат выполнения команды."""
    payload = request.get_json(force=True, silent=True) or {}
    command_id = payload.get("id")
    if command_id:
        with pending_lock:
            holder = pending_responses.get(command_id)
            if holder:
                holder["response"] = payload
                holder["event"].set()
                return jsonify({"ok": True})
    # Ответ без известного id (например, старый формат плагина) — просто логируем
    print(f"[MCP] ← Studio (без id): {payload}")
    return jsonify({"ok": True})


# ============================================================
# Эндпоинты MCP для работы с объектами Studio
# ============================================================


@app.route("/api/file-tree", methods=["GET"])
def file_tree():
    """Возвращает дерево объектов DataModel (через плагин)."""
    result = make_command("file_tree")
    status = 200 if "error" not in result else 504
    return jsonify(result), status


@app.route("/api/script", methods=["GET"])
def read_script():
    """Возвращает код скрипта по пути. Пример: /api/script?path=ServerScriptService/MyScript"""
    path = request.args.get("path", "")
    if not path:
        return jsonify({"error": "Не указан параметр path"}), 400
    result = make_command("read_script", path=path)
    status = 200 if "error" not in result else 404
    return jsonify(result), status


@app.route("/api/script", methods=["POST"])
def write_script():
    """Сохраняет код в скрипт в Studio.
    Тело: {path: "ServerScriptService/MyScript", source: "...код..."}"""
    payload = request.get_json(force=True, silent=True) or {}
    path = payload.get("path", "")
    source = payload.get("source")
    if not path or source is None:
        return jsonify({"error": "Нужны поля path и source"}), 400
    result = make_command("write_script", path=path, source=source)
    status = 200 if "error" not in result else 404
    return jsonify(result), status


@app.route("/api/instance", methods=["POST"])
def create_instance():
    """Создаёт объект. Тело: {className, name, parent} (parent — путь или 'Workspace')."""
    payload = request.get_json(force=True, silent=True) or {}
    class_name = payload.get("className", "")
    name = payload.get("name", "")
    parent = payload.get("parent", "Workspace")
    if not class_name or not name:
        return jsonify({"error": "Нужны поля className и name"}), 400
    result = make_command(
        "create_instance", className=class_name, name=name, parent=parent
    )
    status = 200 if "error" not in result else 400
    return jsonify(result), status


@app.route("/api/instance", methods=["DELETE"])
def delete_instance():
    """Удаляет объект по пути. Пример: DELETE /api/instance?path=Workspace/MyPart"""
    path = request.args.get("path", "")
    if not path:
        return jsonify({"error": "Не указан параметр path"}), 400
    result = make_command("delete_instance", path=path)
    status = 200 if "error" not in result else 404
    return jsonify(result), status


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    print(f"[MCP] MCP-сервер слушает http://localhost:{MCP_PORT}")
    print("[MCP] Ждём плагин Roblox Studio (RobloxStudioPlugin.lua)...")
    # threaded=True — плагин опрашивает /api/command, пока MCP-клиенты ждут ответы
    app.run(host="0.0.0.0", port=MCP_PORT, threaded=True)
