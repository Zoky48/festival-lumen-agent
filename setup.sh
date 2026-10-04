#!/usr/bin/env bash
set -euo pipefail

APP_USER="zoky"
APP_DIR="/home/${APP_USER}/festival-lumen-agent"

mkdir -p "${APP_DIR}"
mkdir -p "${APP_DIR}/data"

if [[ ! -f "${APP_DIR}/.env" ]]; then
  cp ".env.example" "${APP_DIR}/.env"
fi

cat > "${APP_DIR}/app.py" <<'PY'
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

DB_PATH = BASE_DIR / "data" / "festival.db"
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
APP_HOST = os.getenv("APP_HOST", "0.0.0.0")
APP_PORT = int(os.getenv("APP_PORT", "8080"))
APP_PASSWORD = os.getenv("APP_PASSWORD", "festival123")
ENABLE_THINKING = os.getenv("ENABLE_THINKING", "false").lower() == "true"
SYSTEM_PROMPT = os.getenv(
    "SYSTEM_PROMPT",
    "Si pomocny AI agent pre hudobny festival Festival Lumen. Odpovedaj po slovensky.",
)

app = FastAPI(title="Festival Lumen Agent")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "najdi_kapelu",
            "description": "Vyhlada kapelu podľa mena, kontaktu, žánru alebo poznámky.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Text vyhľadávania."}
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "pridaj_kapelu",
            "description": "Pridá novú kapelu do databázy.",
            "parameters": {
                "type": "object",
                "properties": {
                    "meno": {"type": "string"},
                    "kontakt": {"type": "string"},
                    "zaner": {"type": "string"},
                    "honorar": {"type": "string"},
                    "rider": {"type": "string"},
                    "stav": {"type": "string"},
                    "poznamky": {"type": "string"},
                },
                "required": ["meno", "kontakt"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "zoznam_kapiel",
            "description": "Vrati zoznam kapiel s možným filtrom.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filter": {"type": "string", "description": "Voliteľný filter, napr. 'stav=potvrdena'"}
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "zmen_stav",
            "description": "Zmení stav kapely.",
            "parameters": {
                "type": "object",
                "properties": {
                    "meno": {"type": "string"},
                    "novy_stav": {"type": "string"},
                },
                "required": ["meno", "novy_stav"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "pridaj_poznamku",
            "description": "Pridá poznámku ku kapely.",
            "parameters": {
                "type": "object",
                "properties": {
                    "meno": {"type": "string"},
                    "poznamka": {"type": "string"},
                },
                "required": ["meno", "poznamka"],
            },
        },
    },
]


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    conn = get_db()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS tool_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool_name TEXT NOT NULL,
            args TEXT,
            result TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS bands (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meno TEXT NOT NULL,
            kontakt TEXT,
            zaner TEXT,
            honorar TEXT,
            rider TEXT,
            stav TEXT DEFAULT 'caká',
            poznamky TEXT,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.commit()
    conn.close()

    save_setting("ollama_base_url", OLLAMA_BASE_URL)
    save_setting("ollama_model", OLLAMA_MODEL)
    save_setting("system_prompt", SYSTEM_PROMPT)
    save_setting("enable_thinking", str(ENABLE_THINKING).lower())
    save_setting("app_password", APP_PASSWORD)


def set_default_settings() -> None:
    save_setting("ollama_base_url", OLLAMA_BASE_URL)
    save_setting("ollama_model", OLLAMA_MODEL)
    save_setting("system_prompt", SYSTEM_PROMPT)
    save_setting("enable_thinking", str(ENABLE_THINKING).lower())
    save_setting("app_password", APP_PASSWORD)


def save_setting(key: str, value: str) -> None:
    conn = get_db()
    conn.execute(
        """
        INSERT INTO settings(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, value),
    )
    conn.commit()
    conn.close()


def get_setting(key: str, fallback: str = "") -> str:
    conn = get_db()
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else fallback


def add_tool_log(tool_name: str, args: Dict[str, Any], result: Any) -> None:
    conn = get_db()
    conn.execute(
        "INSERT INTO tool_log(tool_name, args, result) VALUES(?, ?, ?)",
        (tool_name, json.dumps(args, ensure_ascii=False), str(result)),
    )
    conn.commit()
    conn.close()


def normalize_status(value: str) -> str:
    normalized = (value or "").strip().lower()
    mapping = {
        "oslovená": "oslovená",
        "oslovena": "oslovená",
        "caká": "čaká",
        "caka": "čaká",
        "potvrdená": "potvrdená",
        "potvrdena": "potvrdená",
        "zrušená": "zrušená",
        "zrusena": "zrušená",
    }
    return mapping.get(normalized, normalized)


def tool_najdi_kapelu(query: str) -> str:
    q = (query or "").strip()
    if not q:
        return "Chýba query. Zadaj text pre vyhľadanie."
    conn = get_db()
    rows = conn.execute(
        """
        SELECT * FROM bands
        WHERE lower(meno) LIKE ? OR lower(kontakt) LIKE ? OR lower(zaner) LIKE ? OR lower(poznamky) LIKE ?
        ORDER BY updated_at DESC
        """,
        (f"%{q.lower()}%", f"%{q.lower()}%", f"%{q.lower()}%", f"%{q.lower()}%"),
    ).fetchall()
    conn.close()
    if not rows:
        return "Nenašla sa žiadna kapela podľa zadaného kritéria."
    lines = []
    for row in rows:
        lines.append(
            f"{row['id']}. {row['meno']} | kontakt: {row['kontakt']} | žáner: {row['zaner']} | stav: {row['stav']} | honorár: {row['honorar']}"
        )
    return "\\n".join(lines)


def tool_pridaj_kapelu(
    meno: str,
    kontakt: str,
    zaner: str = "",
    honorar: str = "",
    rider: str = "",
    stav: str = "čaká",
    poznamky: str = "",
) -> str:
    if not meno or not kontakt:
        return "Meno a kontakt sú povinné."
    conn = get_db()
    conn.execute(
        """
        INSERT INTO bands(meno, kontakt, zaner, honorar, rider, stav, poznamky)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        """,
        (meno, kontakt, zaner, honorar, rider, normalize_status(stav or "čaká"), poznamky),
    )
    conn.commit()
    conn.close()
    return f"Kapela '{meno}' bola pridaná."


def tool_zoznam_kapiel(filter: str = "") -> str:
    conn = get_db()
    rows = []
    if filter and "=" in filter:
        key, value = [part.strip() for part in filter.split("=", 1)]
        key = key.lower()
        if key in {"stav", "status"}:
            rows = conn.execute(
                "SELECT * FROM bands WHERE lower(stav) = ? ORDER BY updated_at DESC",
                (normalize_status(value).lower(),),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM bands WHERE lower(meno) LIKE ? OR lower(kontakt) LIKE ? OR lower(zaner) LIKE ? ORDER BY updated_at DESC",
                (f"%{value.lower()}%", f"%{value.lower()}%", f"%{value.lower()}%"),
            ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM bands ORDER BY updated_at DESC").fetchall()
    conn.close()
    if not rows:
        return "V databáze nie sú žiadne kapely."
    lines = []
    for row in rows:
        lines.append(
            f"{row['id']}. {row['meno']} | kontakt: {row['kontakt']} | žáner: {row['zaner']} | stav: {row['stav']} | honorár: {row['honorar']}"
        )
    return "\\n".join(lines)


def tool_zmen_stav(meno: str, novy_stav: str) -> str:
    if not meno:
        return "Chýba meno kapely."
    new_status = normalize_status(novy_stav or "")
    if not new_status:
        return "Neplatný stav. Použi: oslovená, čaká, potvrdená, zrušená."
    conn = get_db()
    row = conn.execute("SELECT id FROM bands WHERE lower(meno) = ?", (meno.lower(),)).fetchone()
    if not row:
        conn.close()
        return f"Nepodarilo sa nájsť kapelu '{meno}'."
    conn.execute(
        "UPDATE bands SET stav = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        (new_status, row["id"]),
    )
    conn.commit()
    conn.close()
    return f"Stav kapely '{meno}' bol zmenený na '{new_status}'."


def tool_pridaj_poznamku(meno: str, poznamka: str) -> str:
    if not meno or not poznamka:
        return "Meno a poznámka sú povinné."
    conn = get_db()
    row = conn.execute("SELECT id, poznamky FROM bands WHERE lower(meno) = ?", (meno.lower(),)).fetchone()
    if not row:
        conn.close()
        return f"Nepodarilo sa nájsť kapelu '{meno}'."
    current = row["poznamky"] or ""
    new_value = f"{current}\n- {poznamka}" if current else f"- {poznamka}"
    conn.execute(
        "UPDATE bands SET poznamky = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        (new_value, row["id"]),
    )
    conn.commit()
    conn.close()
    return f"Poznámka bola pridaná ku kapely '{meno}'."


TOOL_FUNCTIONS = {
    "najdi_kapelu": tool_najdi_kapelu,
    "pridaj_kapelu": tool_pridaj_kapelu,
    "zoznam_kapiel": tool_zoznam_kapiel,
    "zmen_stav": tool_zmen_stav,
    "pridaj_poznamku": tool_pridaj_poznamku,
}


def call_ollama(messages: List[Dict[str, Any]], tools: List[Dict[str, Any]]) -> Dict[str, Any]:
    payload = {
        "model": get_setting("ollama_model", OLLAMA_MODEL),
        "messages": messages,
        "tools": tools,
        "stream": False,
        "options": {"temperature": 0.2},
    }
    if get_setting("enable_thinking", str(ENABLE_THINKING).lower()) == "true":
        payload["think"] = True
    else:
        payload["think"] = False

    response = requests.post(
        f"{get_setting('ollama_base_url', OLLAMA_BASE_URL)}/api/chat",
        json=payload,
        timeout=90,
    )
    if response.status_code != 200:
        raise RuntimeError(f"Ollama API error: {response.text}")
    return response.json()


def execute_tool(name: str, arguments: Dict[str, Any]) -> str:
    tool_fn = TOOL_FUNCTIONS.get(name)
    if not tool_fn:
        return f"Nástroj '{name}' nie je podporovaný."
    try:
        result = tool_fn(**arguments)
        add_tool_log(name, arguments, result)
        return str(result)
    except Exception as exc:
        return f"Nástroj '{name}' zlyhal: {exc}"


def agent_loop(user_message: str) -> Dict[str, Any]:
    conn = get_db()
    history = [
        {"role": row["role"], "content": row["content"]}
        for row in conn.execute("SELECT role, content FROM messages ORDER BY id ASC").fetchall()
    ]
    conn.close()

    system_message = {"role": "system", "content": get_setting("system_prompt", SYSTEM_PROMPT)}
    messages: List[Dict[str, Any]] = [system_message, *history, {"role": "user", "content": user_message}]

    final_text = ""
    tool_trace: List[Dict[str, Any]] = []

    for _ in range(8):
        response = call_ollama(messages, TOOL_DEFINITIONS)
        msg = response.get("message", {})
        content = msg.get("content") or ""
        tool_calls = msg.get("tool_calls") or []

        if content and not tool_calls:
            final_text = content
            break

        if not tool_calls:
            final_text = content or "Agent nevrátil finálnu odpoveď."
            break

        for tool_call in tool_calls:
            fn = tool_call.get("function") or tool_call
            tool_name = fn.get("name")
            arguments = fn.get("arguments") or {}
            tool_trace.append({"tool": tool_name, "args": arguments})
            tool_result = execute_tool(tool_name, arguments)
            messages.append({"role": "assistant", "content": "", "tool_calls": [tool_call]})
            messages.append({"role": "tool", "name": tool_name, "content": tool_result})

    if not final_text:
        final_text = "Agent nevrátil finálnu odpoveď. Skús to znova."

    return {"answer": final_text, "tool_trace": tool_trace, "steps": len(tool_trace)}


async def ensure_authenticated(request: Request):
    session = request.cookies.get("festival_session")
    if session != "logged_in":
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.get("/login", response_class=HTMLResponse)
def login_page():
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Festival Lumen Agent</title>
      <style>
        body {
          font-family: Arial, sans-serif;
          background: #111827;
          color: #f3f4f6;
          margin: 0;
          display: grid;
          place-items: center;
          height: 100vh;
        }
        .box {
          width: min(420px, 90vw);
          background: #1f2937;
          padding: 24px;
          border-radius: 16px;
          border: 1px solid #374151;
        }
        input, button {
          width: 100%;
          box-sizing: border-box;
          margin-top: 10px;
          padding: 12px;
          border-radius: 8px;
          border: 1px solid #374151;
        }
        button {
          background: #2563eb;
          color: white;
          border: none;
          font-weight: bold;
          cursor: pointer;
        }
      </style>
    </head>
    <body>
      <div class="box">
        <h2>Festival Lumen Agent</h2>
        <form method="post" action="/login">
          <label>Heslo</label>
          <input type="password" name="password" placeholder="Zadaj heslo" required>
          <button type="submit">Prihlásiť sa</button>
        </form>
      </div>
    </body>
    </html>
    """


@app.post("/login")
def login_post(request: Request):
    form = request.form()
    submitted = (await form if hasattr(form, '__await__') else form)


@app.get("/logout")
def logout():
    response = RedirectResponse(url="/login", status_code=302)
    response.delete_cookie("festival_session")
    return response


@app.post("/login")
def login_post_form(password: str = ""):
    if password == get_setting("app_password", APP_PASSWORD):
        response = RedirectResponse(url="/", status_code=302)
        response.set_cookie("festival_session", "logged_in", httponame="festival_session")
        return response
    raise HTTPException(status_code=401, detail="Nesprávne heslo")


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    session = request.cookies.get("festival_session")
    if session != "logged_in":
        return RedirectResponse(url="/login", status_code=302)
    return """
    <!doctype html>
    <html lang="sk">
    <head>
      <meta charset="utf-8">
      <title>Festival Lumen Agent</title>
      <style>
        body { font-family: Arial, sans-serif; margin: 0; background: #111827; color: #f3f4f6; }
        .container { max-width: 1100px; margin: 0 auto; padding: 24px; }
        .topbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 18px; }
        .grid { display: grid; grid-template-columns: 1.3fr 0.7fr; gap: 16px; }
        .panel { background: #1f2937; border: 1px solid #374151; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
        .messages { min-height: 240px; max-height: 420px; overflow-y: auto; background: #0f172a; border-radius: 8px; padding: 12px; }
        .msg { padding: 8px 10px; border-radius: 8px; margin-bottom: 10px; }
        .user { background: #1d4ed8; }
        .assistant { background: #374151; }
        .tool { background: #14532d; }
        textarea, input, select, button { width: 100%; box-sizing: border-box; margin-top: 8px; padding: 10px; border-radius: 8px; border: 1px solid #374151; }
        button { background: #2563eb; color: white; border: none; font-weight: bold; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; }
        th, td { text-align: left; padding: 8px; border-bottom: 1px solid #374151; }
        .small { font-size: 12px; color: #cbd5e1; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="topbar">
          <h2>Festival Lumen Agent</h2>
          <a href="/logout" style="color:white;">Odhlásiť sa</a>
        </div>

        <div class="panel">
          <h3>Nastavenia</h3>
          <label>Model</label>
          <input id="model" value="qwen3:8b">
          <label>Ollama URL</label>
          <input id="ollama_url" value="http://127.0.0.1:11434">
          <label>System prompt</label>
          <textarea id="system_prompt" rows="4">Si pomocny AI agent pre hudobny festival Festival Lumen. Odpovedaj po slovensky.</textarea>
          <label>Heslo</label>
          <input id="app_password" type="password" value="festival123">
          <label>Thinking</label>
          <select id="enable_thinking">
            <option value="false">Vypnuté</option>
            <option value="true">Zapnuté</option>
          </select>
          <button onclick="saveSettings()">Uložiť nastavenia</button>
        </div>

        <div class="grid">
          <div class="panel">
            <h3>Chat</h3>
            <div id="messages" class="messages"></div>
            <textarea id="prompt" rows="4" placeholder="Napíš prompt pre agenta..."></textarea>
            <button onclick="sendMessage()">Odoslať</button>
          </div>

          <div class="panel">
            <h3>Kapely</h3>
            <input id="band_name" placeholder="Meno kapely">
            <input id="band_contact" placeholder="Kontakt">
            <input id="band_genre" placeholder="Žáner">
            <input id="band_fee" placeholder="Honorár">
            <input id="band_rider" placeholder="Technické požiadavky">
            <select id="band_status">
              <option value="čaká">čaká</option>
              <option value="oslovená">oslovená</option>
              <option value="potvrdená">potvrdená</option>
              <option value="zrušená">zrušená</option>
            </select>
            <textarea id="band_notes" rows="3" placeholder="Poznámky"></textarea>
            <button onclick="addBand()">Pridať kapelu</button>
            <div id="bands" class="small"></div>
          </div>
        </div>
      </div>

      <script>
        async function api(path, method = 'GET', payload = null) {
          const options = { method, headers: { 'Content-Type': 'application/json' } };
          if (payload !== null) options.body = JSON.stringify(payload);
          const res = await fetch(path, options);
          const data = await res.json();
          if (!res.ok) throw new Error(data.detail || 'Chyba');
          return data;
        }

        async function loadSettings() {
          const data = await api('/api/settings');
          document.getElementById('model').value = data.ollama_model || 'qwen3:8b';
          document.getElementById('ollama_url').value = data.ollama_base_url || 'http://127.0.0.1:11434';
          document.getElementById('system_prompt').value = data.system_prompt || 'Si pomocny AI agent pre hudobny festival Festival Lumen. Odpovedaj po slovensky.';
          document.getElementById('app_password').value = data.app_password || 'festival123';
          document.getElementById('enable_thinking').value = data.enable_thinking === 'true' ? 'true' : 'false';
          await loadBands();
        }

        async function saveSettings() {
          try {
            const payload = {
              ollama_model: document.getElementById('model').value,
              ollama_base_url: document.getElementById('ollama_url').value,
              system_prompt: document.getElementById('system_prompt').value,
              app_password: document.getElementById('app_password').value,
              enable_thinking: document.getElementById('enable_thinking').value
            };
            const res = await api('/api/settings', 'POST', payload);
            alert(res.message || 'Nastavenia uložené');
          } catch (err) {
            alert(err.message);
          }
        }

        async function sendMessage() {
          const prompt = document.getElementById('prompt').value.trim();
          if (!prompt) return;
          const msgBox = document.getElementById('messages');
          msgBox.innerHTML += `<div class='msg user'>Ty: ${prompt}</div>`;
          document.getElementById('prompt').value = '';

          try {
            const data = await api('/api/chat', 'POST', { message: prompt });
            msgBox.innerHTML += `<div class='msg assistant'>Agent: ${data.answer}</div>`;
            if (data.tool_trace && data.tool_trace.length) {
              msgBox.innerHTML += `<div class='msg tool'>Nástroje: ${JSON.stringify(data.tool_trace)}</div>`;
            }
          } catch (err) {
            msgBox.innerHTML += `<div class='msg tool'>Chyba: ${err.message}</div>`;
          }
          msgBox.scrollTop = msgBox.scrollHeight;
        }

        async function addBand() {
          const payload = {
            meno: document.getElementById('band_name').value,
            kontakt: document.getElementById('band_contact').value,
            zaner: document.getElementById('band_genre').value,
            honorar: document.getElementById('band_fee').value,
            rider: document.getElementById('band_rider').value,
            stav: document.getElementById('band_status').value,
            poznamky: document.getElementById('band_notes').value
          };

          try {
            const res = await api('/api/bands', 'POST', payload);
            alert(res.message || 'Kapela pridaná');
            await loadBands();
          } catch (err) {
            alert(err.message);
          }
        }

        async function loadBands() {
          try {
            const rows = await api('/api/bands');
            const list = rows.length ? rows : [];
            const el = document.getElementById('bands');
            if (!list.length) {
              el.innerHTML = '<p>Žiadne kapely.</p>';
              return;
            }
            let html = '<table><thead><tr><th>Meno</th><th>Žáner</th><th>Stav</th></tr></thead><tbody>';
            for (const item of list) {
              html += `<tr><td>${item.meno}</td><td>${item.zaner || '-'}</td><td>${item.stav || '-'}</td></tr>`;
            }
            html += '</tbody></table>';
            el.innerHTML = html;
          } catch (err) {
            document.getElementById('bands').innerHTML = '<p>Chyba pri načítaní kapiel.</p>';
          }
        }

        loadSettings();
      </script>
    </body>
    </html>
    """


@app.get("/api/settings")
def get_settings_api():
    return {
        "ollama_base_url": get_setting("ollama_base_url", OLLAMA_BASE_URL),
        "ollama_model": get_setting("ollama_model", OLLAMA_MODEL),
        "system_prompt": get_setting("system_prompt", SYSTEM_PROMPT),
        "app_password": get_setting("app_password", APP_PASSWORD),
        "enable_thinking": get_setting("enable_thinking", str(ENABLE_THINKING).lower()),
    }


@app.post("/api/settings")
def save_settings_api(payload: dict):
    if "ollama_base_url" in payload:
        save_setting("ollama_base_url", str(payload["ollama_base_url"]))
    if "ollama_model" in payload:
        save_setting("ollama_model", str(payload["ollama_model"]))
    if "system_prompt" in payload:
        save_setting("system_prompt", str(payload["system_prompt"]))
    if "app_password" in payload:
        save_setting("app_password", str(payload["app_password"]))
    if "enable_thinking" in payload:
        save_setting("enable_thinking", str(payload["enable_thinking"]).lower())
    return {"message": "Nastavenia uložené."}


@app.post("/api/chat")
def chat_api(payload: dict):
    message = (payload.get("message") or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="Chýba text správy.")
    conn = get_db()
    conn.execute("INSERT INTO messages(role, content) VALUES(?, ?)", ("user", message))
    conn.commit()
    conn.close()

    result = agent_loop(message)
    conn = get_db()
    conn.execute("INSERT INTO messages(role, content) VALUES(?, ?)", ("assistant", result["answer"]))
    conn.commit()
    conn.close()
    return result


@app.get("/api/bands")
def list_bands_api():
    conn = get_db()
    rows = conn.execute("SELECT * FROM bands ORDER BY updated_at DESC").fetchall()
    conn.close()
    return [dict(row) for row in rows]


@app.post("/api/bands")
def add_band_api(payload: dict):
    if not payload.get("meno") or not payload.get("kontakt"):
        raise HTTPException(status_code=400, detail="Meno a kontakt sú povinné.")

    conn = get_db()
    conn.execute(
        """
        INSERT INTO bands(meno, kontakt, zaner, honorar, rider, stav, poznamky)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        """,
        (
            payload.get("meno", ""),
            payload.get("kontakt", ""),
            payload.get("zaner", ""),
            payload.get("honorar", ""),
            payload.get("rider", ""),
            normalize_status(payload.get("stav", "čaká")),
            payload.get("poznamky", ""),
        ),
    )
    conn.commit()
    conn.close()
    return {"message": "Kapela bola pridaná."}


@app.on_event("startup")
def startup_event():
    init_db()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=APP_HOST, port=APP_PORT)
PY

cat > "${APP_DIR}/setup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/home/${USER}/festival-lumen-agent"

if [[ ! -d "${APP_DIR}/.venv" ]]; then
  python3 -m venv "${APP_DIR}/.venv"
fi

source "${APP_DIR}/.venv/bin/activate"
python -m pip install --upgrade pip
pip install -r "${APP_DIR}/requirements.txt"

if [[ ! -f "${APP_DIR}/.env" ]]; then
  cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
fi

python - <<'PY'
import os
import sys
sys.path.insert(0, "/home/${USER}/festival-lumen-agent")
import app
app.init_db()
print("DB initialized")
PY

echo "Setup finished."
SH

chmod +x "${APP_DIR}/setup.sh"

cat > "${APP_DIR}/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn==0.30.6
pydantic==2.9.2
python-dotenv==1.0.1
requests==2.32.2
EOF

cat > "${APP_DIR}/.env.example" <<'EOF'
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3:8b
APP_HOST=0.0.0.0
APP_PORT=8080
APP_PASSWORD=festival123
ENABLE_THINKING=false
SYSTEM_PROMPT=Si pomocny AI agent pre hudobny festival Festival Lumen. Odpovedaj po slovensky.
EOF

cat > "${APP_DIR}/README.md" <<'EOF'
# Festival Lumen Agent

Základný self-hosted AI agent pre Festival Lumen.

## Quick start

```bash
chmod +x setup.sh
./setup.sh
```

Aplikácia beží na port `8080`.

## Manual start

```bash
cd /home/zoky/festival-lumen-agent
source .venv/bin/activate
python app.py
```

## Login

Heslo je v `.env`:

```env
APP_PASSWORD=festival123
```

## Config

- `OLLAMA_BASE_URL`
- `OLLAMA_MODEL`
- `SYSTEM_PROMPT`
- `ENABLE_THINKING`

## Notes

- Ollama must run on `127.0.0.1:11434`
- This is a solid base for future email, TickTick and WhatsApp modules.
EOF

mkdir -p "${APP_DIR}/static"
cat > "${APP_DIR}/static/.gitkeep" <<'EOF'
placeholder
EOF

cat > "/etc/systemd/system/festival-lumen-agent.service" <<'EOF'
[Unit]
Description=Festival Lumen Agent
After=network.target

[Service]
Type=simple
User=zoky
WorkingDirectory=/home/zoky/festival-lumen-agent
ExecStart=/home/zoky/festival-lumen-agent/.venv/bin/python /home/zoky/festival-lumen-agent/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now festival-lumen-agent.service

echo "Repo setup completed."
