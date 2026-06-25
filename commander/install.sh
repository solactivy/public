#!/usr/bin/env bash
# Commander one-shot installer (runs the published GHCR image via docker compose).
#
# Usage:
#   GHCR_USER=solactivy GHCR_PAT=ghp_xxx ./install.sh
#
# Env vars:
#   GHCR_USER        GitHub username for GHCR login (default: solactivy)
#   GHCR_PAT         GitHub PAT with read:packages (skip if package is public)
#   COMMANDER_OWNER  image owner (default: solactivy)
#   COMMANDER_TAG    image tag   (default: latest)
#   INSTALL_DIR      target dir  (default: ./commander)
set -euo pipefail

GHCR_USER="${GHCR_USER:-solactivy}"
COMMANDER_OWNER="${COMMANDER_OWNER:-solactivy}"
COMMANDER_TAG="${COMMANDER_TAG:-latest}"
INSTALL_DIR="${INSTALL_DIR:-./commander}"
IMAGE="ghcr.io/${COMMANDER_OWNER}/commander:${COMMANDER_TAG}"

command -v docker >/dev/null || { echo "docker not found — install Docker first"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin not found"; exit 1; }

mkdir -p "$INSTALL_DIR"/{data,logs}
cd "$INSTALL_DIR"

# --- compose file ---
cat > docker-compose.yml <<EOF
services:
  commander:
    image: ${IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "8088:8088"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:8088/api/agents', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF

# --- .env template (only created if missing, so we never clobber secrets) ---
if [ ! -f .env ]; then
  cat > .env <<'EOF'
# ---- Telegram (required) ----
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ALLOWED_CHAT_IDS=

# ---- LLM keys ----
ANTHROPIC_API_KEY=
OPENROUTER_API_KEY=

# ---- Storage / agents ----
STORAGE_PROVIDER=json
AGENTS_DATA_DIR=./data

# ---- Webapp ----
WEBAPP_ENABLED=true
WEBAPP_PORT=8088

# ---- Misc ----
LOG_LEVEL=info
TZ_DISPLAY=Europe/Lisbon
EOF
  echo ">> Created .env template — fill in TELEGRAM_BOT_TOKEN / ANTHROPIC_API_KEY etc., then re-run."
  echo ">> Edit: $(pwd)/.env"
  exit 0
fi

# --- login (only if a PAT was provided) ---
if [ -n "${GHCR_PAT:-}" ]; then
  echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi

# --- pull & run ---
docker compose pull
docker compose up -d

echo ">> Commander is starting. UI: http://localhost:8088"
echo ">> Logs: (cd $(pwd) && docker compose logs -f)"
