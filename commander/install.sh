#!/usr/bin/env bash
# Commander one-shot installer — prompts for config, then runs the GHCR image.
#
#   curl -fsSL https://raw.githubusercontent.com/solactivy/public/main/commander/install.sh | bash
#
# Works both when run directly and when piped from curl (prompts read /dev/tty).
set -euo pipefail

COMMANDER_OWNER="${COMMANDER_OWNER:-solactivy}"
COMMANDER_TAG="${COMMANDER_TAG:-latest}"
INSTALL_DIR="${INSTALL_DIR:-}"
IMAGE="ghcr.io/${COMMANDER_OWNER}/commander:${COMMANDER_TAG}"

command -v docker >/dev/null || { echo "❌ docker not found — install Docker first"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "❌ docker compose plugin not found"; exit 1; }

# All prompts read from the terminal, so this works under `curl | bash`.
TTY=/dev/tty
ask()      { local p="$1" v=""; while [ -z "$v" ]; do printf '%s' "$p" >"$TTY"; read -r v <"$TTY"; done; printf '%s' "$v"; }
ask_opt()  { local p="$1" v="";   printf '%s' "$p" >"$TTY"; read -r v <"$TTY"; printf '%s' "$v"; }
ask_secret(){ local p="$1" v=""; while [ -z "$v" ]; do printf '%s' "$p" >"$TTY"; read -rs v <"$TTY"; echo >"$TTY"; done; printf '%s' "$v"; }
ask_secret_opt(){ local p="$1" v=""; printf '%s' "$p" >"$TTY"; read -rs v <"$TTY"; echo >"$TTY"; printf '%s' "$v"; }

echo "── Commander setup ──────────────────────────────"
# Suggest a random nature / ocean / sports themed name (user can override).
SUFFIXES=(wave ocean reef tide coral current breeze forest river canyon summit \
          meadow harbor glacier cliff falcon otter heron marlin surf sprint \
          rally striker rover comet ember willow cedar aspen pine)
SUGGEST="commander-${SUFFIXES[$((RANDOM % ${#SUFFIXES[@]}))]}"
NAME=$(ask_opt "Commander name [${SUGGEST}]: "); NAME="${NAME:-$SUGGEST}"
# sanitize: lowercase, only [a-z0-9_-], used for dir / service / volume names
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//')
[ -n "$NAME" ] || NAME=commander
INSTALL_DIR="${INSTALL_DIR:-./$NAME}"
PORT=$(ask_opt "Host port [8088]: "); PORT="${PORT:-8088}"
echo
echo "GitHub credentials — required to pull the private image."
GHCR_USER=$(ask_opt  "GitHub username [${COMMANDER_OWNER}]: "); GHCR_USER="${GHCR_USER:-$COMMANDER_OWNER}"
GHCR_PAT=$(ask_secret "GitHub PAT (read:packages): ")

# Validate the PAT up front — fail fast before asking for anything else.
echo ">> Logging in to GHCR as ${GHCR_USER}…"
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo
BOT_TOKEN=$(ask      "Telegram bot token: ")
CHAT_ID=$(ask        "Telegram chat ID (your numeric ID): ")
ANTHROPIC=$(ask_secret_opt "Anthropic API key (sk-ant-…, blank to add later): ")

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

cat > docker-compose.yml <<EOF
name: ${NAME}
services:
  ${NAME}:
    image: ${IMAGE}
    container_name: ${NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${PORT}:8088"
    volumes:
      - ${NAME}_data:/app/data
      - ${NAME}_logs:/app/logs
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:8088/api/agents', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  ${NAME}_data:
  ${NAME}_logs:
EOF

cat > .env <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
ANTHROPIC_API_KEY=${ANTHROPIC}
STORAGE_PROVIDER=json
WEBAPP_ENABLED=true
WEBAPP_PORT=8088
LOG_LEVEL=info
EOF
chmod 600 .env

echo ">> Pulling image…"
docker compose pull
echo ">> Starting…"
docker compose up -d

echo
echo "✅ Commander '${NAME}' is up. UI: http://localhost:${PORT}"
echo "   Logs: (cd $(pwd) && docker compose logs -f)"
