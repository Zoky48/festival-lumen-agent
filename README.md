# Festival Lumen Agent

Self-hosted AI assistant for Festival Lumen. This repo contains a working base implementation with:
- FastAPI web app
- SQLite persistence
- Ollama tool-calling loop
- simple admin login
- band management UI
- configurable model, URL, system prompt and thinking toggle

It is designed to run on Ubuntu server and be reachable over Tailscale while Ollama stays local on localhost.

## Features
- Slovak chat UI
- tool-calling agent using Ollama
- SQLite history and logs
- band database with fields: name, contact, genre, fee, rider, status, notes
- settings UI for model/URL/system prompt
- simple single-password web login
- systemd service file for service deployment

## Quick start

1. Clone the repo
2. Run setup script

```bash
chmod +x setup.sh
./setup.sh
```

This will:
- create Python virtual environment
- install dependencies
- create `.env` config
- initialize SQLite DB
- install systemd service
- start app on port 8080

## Manual start

```bash
cd /home/zoky/festival-lumen-agent
source .venv/bin/activate
python app.py
```

Then open:
- `http://localhost:8080`
- or Tailscale IP of the server

## Default login

Password is defined in `.env` under `APP_PASSWORD`.

Default example:

```env
APP_PASSWORD=festival123
```

## Config

Edit `.env` or change values in the web settings page.

Important variables:

```env
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3:8b
APP_HOST=0.0.0.0
APP_PORT=8080
APP_PASSWORD=festival123
ENABLE_THINKING=false
SYSTEM_PROMPT=Si pomocny AI agent pre hudobny festival Festival Lumen. Odpovedaj po slovensky.
```

## Systemd

Service file is installed at:

```bash
/etc/systemd/system/festival-lumen-agent.service
```

Check logs:

```bash
sudo journalctl -u festival-lumen-agent -f
```

## Tailscale

Run the app on the server and open it via the Tailscale IP. Ollama remains local only (`127.0.0.1:11434`).

## Notes

- This is the base architecture for the final product.
- Email, TickTick, and WhatsApp integrations are intentionally separated into later modules.
- Agent tools are intentionally small and explicit so Qwen3:8b can work reliably.

## Development notes

This project is intentionally simple and readable for learning. The important logic lives in `app.py` and is intentionally compact.
