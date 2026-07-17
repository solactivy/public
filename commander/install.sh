#!/usr/bin/env bash
#
# Commander one-shot installer — interactive, supports in-chat /update.
#
#   curl -fsSL https://raw.githubusercontent.com/solactivy/public/main/commander/install.sh | sudo bash
#
# Requires root (docker socket mount + uid-1000 ownership for self-update).
# Prompts read /dev/tty, so it works when piped from curl.
set -euo pipefail

# ---------- config defaults (override via env) ----------
COMMANDER_OWNER="${COMMANDER_OWNER:-solactivy}"
COMMANDER_REPO="${COMMANDER_REPO:-commander}"
COMMANDER_TAG="${COMMANDER_TAG:-latest}"
IMAGE="ghcr.io/${COMMANDER_OWNER}/${COMMANDER_REPO}:${COMMANDER_TAG}"

# ---------- pretty output ----------
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
say()  { printf "%s>> %s%s\n" "$BLUE" "$*" "$RESET"; }
ok()   { printf "%s✓ %s%s\n" "$GREEN" "$*" "$RESET"; }
warn() { printf "%s! %s%s\n" "$YELLOW" "$*" "$RESET"; }

[ "$(id -u)" -eq 0 ] || { echo "❌ Run as root — pipe to 'sudo bash':"; echo "   curl -fsSL <url> | sudo bash"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "❌ docker not found — install Docker first"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "❌ docker compose plugin not found"; exit 1; }

# ---------- prompt helpers (read the terminal even under `curl | bash`) ----------
TTY=/dev/tty
ask()        { local p="$1" v=""; while [ -z "$v" ]; do printf '%s' "$p" >"$TTY"; read -r v <"$TTY"; done; printf '%s' "$v"; }
ask_opt()    { local p="$1" v="";   printf '%s' "$p" >"$TTY"; read -r v <"$TTY"; printf '%s' "$v"; }
ask_secret() { local p="$1" v=""; while [ -z "$v" ]; do printf '%s' "$p" >"$TTY"; read -rs v <"$TTY"; echo >"$TTY"; done; printf '%s' "$v"; }
ask_secret_opt(){ local p="$1" v=""; printf '%s' "$p" >"$TTY"; read -rs v <"$TTY"; echo >"$TTY"; printf '%s' "$v"; }

# Returns 0 if a TCP port is already bound on this host.
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  else
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

echo "── Commander setup ──────────────────────────────"

# --- name (bare; container becomes commander-<name>, matching /update) ---
SUFFIXES=(wave ocean reef tide coral current breeze forest river canyon summit \
          meadow harbor glacier cliff falcon otter heron marlin surf sprint \
          rally striker rover comet ember willow cedar aspen pine)
SUGGEST="${SUFFIXES[$((RANDOM % ${#SUFFIXES[@]}))]}"
NAME=$(ask_opt "Commander name [${SUGGEST}]: "); NAME="${NAME:-$SUGGEST}"
# sanitize: lowercase, [a-z0-9-], no leading/trailing dash
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')
[ -n "$NAME" ] || NAME="$SUGGEST"
CONTAINER="commander-${NAME}"
INSTALL_DIR="${INSTALL_DIR:-/opt/commander-${NAME}}"

# Re-run with the same name = UPGRADE: keep the existing .env/data, just
# refresh the compose file and pull the new image. Fresh name = full setup.
UPGRADE=false
[ -f "$INSTALL_DIR/.env" ] && UPGRADE=true

# --- GitHub credentials (needed to pull, both modes) ---
echo
echo "GitHub credentials — required to pull the private image."
GHCR_USER=$(ask_opt  "GitHub username [${COMMANDER_OWNER}]: "); GHCR_USER="${GHCR_USER:-$COMMANDER_OWNER}"
GHCR_PAT=$(ask_secret "GitHub PAT (read:packages): ")
say "Logging in to GHCR as ${GHCR_USER}…"
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

if [ "$UPGRADE" = true ]; then
  ok "Existing install found at ${INSTALL_DIR} — UPGRADE mode (keeping .env, data & logins)."
  # Reuse the port already recorded in .env (don't re-prompt or it'd flag our
  # own running container as "in use").
  PORT="$(grep -E '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '" ')"
  [ -n "$PORT" ] || PORT=8088
  say "Reusing host port ${PORT}."
else
  # --- host port (validated + checked free) ---
  while :; do
    PORT=$(ask_opt "Host port [8088]: "); PORT="${PORT:-8088}"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
      echo "  ✗ '$PORT' is not a valid port (1-65535)" >"$TTY"; continue
    fi
    if port_in_use "$PORT"; then
      echo "  ✗ port $PORT is already in use — pick another" >"$TTY"; continue
    fi
    break
  done

  echo
  BOT_TOKEN=$(ask        "Telegram bot token: ")
  CHAT_ID=$(ask          "Telegram chat ID (your numeric ID): ")
  ANTHROPIC=$(ask_secret_opt "Anthropic API key (sk-ant-…, blank to add later): ")

  echo
  echo "Web UI login — protects http://<host>:${PORT}/ (blank password = no login)."
  UI_USERNAME=$(ask_opt "  UI username [admin]: "); UI_USERNAME="${UI_USERNAME:-admin}"
  UI_PASSWORD=$(ask_secret_opt "  UI password (blank to disable): ")
  UI_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')
fi

# ---------- write install dir ----------
mkdir -p "$INSTALL_DIR"/{data,logs,claude-config,bw-config,docker-config}
cd "$INSTALL_DIR"

# Seed GHCR creds into a mounted docker-config so the container can also pull
# (private-image fallback for self-update).
echo "$GHCR_PAT" | docker --config "$INSTALL_DIR/docker-config" login ghcr.io -u "$GHCR_USER" --password-stdin

# Host docker GID — lets the container's 'node' user read /var/run/docker.sock.
DOCKER_GID="$(getent group docker | cut -d: -f3 || true)"
[ -n "$DOCKER_GID" ] || { DOCKER_GID="999"; warn "No 'docker' group on host — defaulting DOCKER_GID=999."; }

cat > docker-compose.yml <<EOF
services:
  commander:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    hostname: ${CONTAINER}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - COMMANDER_COMPOSE_DIR=/host/commander      # where the compose file is visible INSIDE the container
      - COMMANDER_HOST_DIR=${INSTALL_DIR}           # real host path — the sibling updater recreates from here
    group_add:
      - "${DOCKER_GID}"
    ports:
      - "${PORT}:8088"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
      - ./claude-config:/home/node/.claude            # persists 'claude' OAuth login
      - ./bw-config:/home/node/.config                # persists Bitwarden CLI login
      - ./docker-config:/home/node/.docker:ro         # GHCR creds for /update
      - /var/run/docker.sock:/var/run/docker.sock     # for self-update
      - ${INSTALL_DIR}:/host/commander:ro             # bot reads compose/env for /update
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:8088/api/agents', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF

# Only write .env on a fresh install — an upgrade keeps the existing one intact.
if [ "$UPGRADE" != true ]; then
cat > .env <<EOF
# --- Identity ---
COMMANDER_NAME=${NAME}

# --- Telegram (required) ---
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
ALLOWED_CHAT_IDS=

# --- Claude / LLM (or set later via /init in chat) ---
ANTHROPIC_API_KEY=${ANTHROPIC}
CLAUDE_CODE_OAUTH_TOKEN=
OPENROUTER_API_KEY=

# --- Web UI auth (blank password disables login) ---
UI_USERNAME=${UI_USERNAME}
UI_PASSWORD=${UI_PASSWORD}
UI_SESSION_SECRET=${UI_SECRET}
UI_SESSION_TTL_SEC=604800

# --- Misc ---
STORAGE_PROVIDER=json
WEBAPP_ENABLED=true
WEBAPP_PORT=8088
HOST_PORT=${PORT}
LOG_LEVEL=info
TZ_DISPLAY=Europe/Lisbon
EOF
fi

# The container runs as uid 1000 ('node'). It must read .env + compose (for
# /update) and write data/logs/claude/bw — own everything accordingly.
chown -R 1000:1000 data logs claude-config bw-config docker-config 2>/dev/null || true
chown 1000:1000 .env docker-compose.yml 2>/dev/null || true
chmod 600 .env docker-config/config.json 2>/dev/null || true
chmod 644 docker-compose.yml 2>/dev/null || true

# ---------- pull + start ----------
say "Pulling image…"
docker compose pull
say "Starting ${CONTAINER}…"
docker compose up -d

sleep 4
if docker compose ps --status running | grep -q "$CONTAINER"; then
  ok "${CONTAINER} is running."
else
  warn "Container did not report running yet — recent logs:"
  docker compose logs --tail 40 commander || true
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; HOST_IP="${HOST_IP:-localhost}"
cat <<EOF

${BOLD}Done.${RESET}  Commander '${NAME}' (container ${CONTAINER})

Web UI:   http://${HOST_IP}:${PORT}
Dir:      ${INSTALL_DIR}     (data/ + claude-config/ are worth backing up)
Logs:     (cd ${INSTALL_DIR} && docker compose logs -f)

Self-update works from chat: send /update to the bot.
Finish setup (Claude, vault, GitHub) from Telegram: send /init.
EOF
