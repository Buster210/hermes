#!/bin/bash
set -euo pipefail
umask 077

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die()  { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# Platforms inject their own PORT (Render); HF/local default to 7860.
PORT="${PORT:-7860}"

# Start health check FIRST, before anything else (HF/Render need a live port immediately)
HEALTH_PORT="$PORT" python3 -c "
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK')
    def log_message(self, *args): pass
HTTPServer(('0.0.0.0', int(os.environ['HEALTH_PORT'])), H).serve_forever()
" &

log "Health check server up on port $PORT"
log "Initializing Hermes Agent..."

if [ -n "${SPACE_ID:-}" ]; then
	PLATFORM="hf"
elif [ -n "${RENDER:-}" ]; then
	PLATFORM="render"
else
	PLATFORM="local"
fi
log "Detected platform: $PLATFORM"

PERSIST_DIR="/data"
APP_DIR="$HOME/app"

# AGENT_NAME guard: required for cloud deployments, random fallback for local
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	[ -n "${AGENT_NAME:-}" ] || die "AGENT_NAME is required on $PLATFORM. Set it via Space/Render secrets."
else
	AGENT_NAME="${AGENT_NAME:-$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])" 2>/dev/null || echo "agent-$$")}"
fi
log "Agent instance: $AGENT_NAME"

HERMES_DATA="/data/${AGENT_NAME}/.hermes"
WORKSPACE_DATA="/data/${AGENT_NAME}/workspace"

command -v hermes >/dev/null 2>&1 || die "hermes binary not found"

# Persistence: scope each agent under /data/<AGENT_NAME>/ and symlink $HOME/.hermes to it.
# Souls live under $APP_DIR/agents (baked, never shadowed by the symlink).
if [ -d "$PERSIST_DIR" ]; then
	log "Persistent storage found at $PERSIST_DIR"
	mkdir -p "$HERMES_DATA" "$WORKSPACE_DATA"
	if [ ! -L "$HOME/.hermes" ]; then
		log "Linking $HOME/.hermes -> $HERMES_DATA (removing any baked .hermes first)"
		rm -rf "$HOME/.hermes"
		ln -s "$HERMES_DATA" "$HOME/.hermes"
	fi
	cd "$WORKSPACE_DATA"
else
	log "No $PERSIST_DIR found — running on ephemeral storage"
	mkdir -p "$HOME/.hermes"
	cd "$APP_DIR"
fi

# Select the SOUL for this agent from the baked agents/<name>/soul.md
SOUL_SRC="$APP_DIR/agents/${AGENT_NAME}/soul.md"
[ -f "$SOUL_SRC" ] || die "no soul at agents/${AGENT_NAME}/soul.md"
cp "$SOUL_SRC" "$HOME/.hermes/SOUL.md"
log "Loaded SOUL for ${AGENT_NAME}"

# Layer per-agent NON-secret overrides (TELEGRAM_BASE_URL, AGENT_PERSONALITY, ...)
AGENT_ENV="$APP_DIR/agents/${AGENT_NAME}/agent.env"
if [ -f "$AGENT_ENV" ]; then
	set -a && . "$AGENT_ENV" && set +a
	log "Loaded per-agent overrides from agents/${AGENT_NAME}/agent.env"
fi

# Local credential bootstrap: seed ~/.hermes/.env from repo .env or environment
if [ "$PLATFORM" = "local" ]; then
	ENV_FILE="$HOME/.hermes/.env"
	if [ -f ".env" ]; then
		cp .env "$ENV_FILE"
		log "Credentials loaded from .env file"
	else
		cat <<EOF >"$ENV_FILE"
HF_TOKEN=${HF_TOKEN:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
GEMINI_API_KEYS=${GEMINI_API_KEYS:-}
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}
TELEGRAM_HOME_CHANNEL=${TELEGRAM_HOME_CHANNEL:-}
GATEWAY_ALLOW_ALL_USERS=${GATEWAY_ALLOW_ALL_USERS:-false}
EOF
		log "Credentials loaded from environment variables"
	fi
	chmod 600 "$ENV_FILE"
fi
# Secrets (TELEGRAM_BOT_TOKEN, GEMINI_API_KEYS, …) are already in the environment via the
# container's env_file/--env-file; we deliberately do NOT source $ENV_FILE here — the
# GEMINI_API_KEYS JSON-list value is not shell-safe and would break under `.`.

# tmate (SSH access) — all platforms. tmate generates its own ephemeral keys; no ssh-keygen needed.
echo "set -g mouse on" >"$HOME/.tmate.conf"
tmate -S /tmp/tmate.sock new-session -d 2>/dev/null || true
for _ in 1 2 3 4 5; do
	SSH_URL=$(tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}' 2>/dev/null || true)
	[ -n "${SSH_URL:-}" ] && break
	sleep 1
done
log "SSH: ${SSH_URL:-tmate failed to connect}"

# Provider defaults
if [ -n "${HF_TOKEN:-}" ]; then
	hermes model set-provider hf --default || warn "HF provider config failed (continuing)"
fi

# Gemini key pool: reset each boot (deterministic), then add every key from GEMINI_API_KEYS.
# Hermes seeds at most 2 keys from env (GOOGLE_API_KEY, GEMINI_API_KEY); the ONLY way to pool
# N keys is `hermes auth add`. Each add gets a random id (no value-dedup), so we clear first.
reset_gemini_pool() {
	# remove index 1 repeatedly until the pool is empty (removal reindexes)
	while hermes auth remove gemini 1 >/dev/null 2>&1; do :; done
}

add_gemini_key() {
	local key="$1"
	[ -n "$key" ] || return 1
	if hermes auth add gemini --type api-key --api-key "$key" >/dev/null 2>&1; then
		log "added gemini key ...${key: -4}"
		return 0
	fi
	warn "failed to add gemini key ...${key: -4}"
	return 1
}

GEMINI_ADDED=0
if [ -n "${GEMINI_API_KEYS:-}" ]; then
	reset_gemini_pool
	while IFS= read -r k; do
		if add_gemini_key "$k"; then GEMINI_ADDED=$((GEMINI_ADDED + 1)); fi
	done < <(
		python3 -c '
import json, sys
try:
    keys = json.loads(sys.argv[1])
except Exception as e:
    sys.stderr.write("GEMINI_API_KEYS parse error: %s\n" % e)
    sys.exit(0)
if not isinstance(keys, list):
    sys.stderr.write("GEMINI_API_KEYS must be a JSON list\n")
    sys.exit(0)
for x in keys:
    x = str(x).strip()
    if x:
        print(x)
' "$GEMINI_API_KEYS"
	)
	log "Gemini pool reset and seeded with $GEMINI_ADDED key(s)"
elif [ -n "${GEMINI_API_KEY:-}" ]; then
	reset_gemini_pool
	if add_gemini_key "$GEMINI_API_KEY"; then GEMINI_ADDED=1; fi
	log "Gemini pool seeded with $GEMINI_ADDED key(s) from GEMINI_API_KEY"
else
	warn "No GEMINI_API_KEYS or GEMINI_API_KEY set — Gemini pool is empty"
fi

# Round-robin across the pooled Gemini keys
hermes config set credential_pool_strategies.gemini round_robin \
	|| warn "Gemini round-robin strategy config failed (continuing)"

# Telegram proxy (HF blocks api.telegram.org). Two mechanisms, both kept:
# 1) native base_url passed to the bot client; 2) legacy sed-patch of installed package files.
TELEGRAM_BASE_URL="${TELEGRAM_BASE_URL:-https://hermes.22f2001388.workers.dev/bot}"
hermes config set gateway.platforms.telegram.extra.base_url "$TELEGRAM_BASE_URL" \
	&& log "telegram base_url -> $TELEGRAM_BASE_URL" \
	|| warn "telegram base_url config failed (continuing)"

if [ -n "${TELEGRAM_PROXY_HOST:-}" ]; then
	SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.11/site-packages")
	find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
		-exec sed -i "s/api.telegram.org/$TELEGRAM_PROXY_HOST/g" {} + 2>/dev/null || true
	log "Telegram proxy (sed-patch) configured: $TELEGRAM_PROXY_HOST"
fi

# Telegram bot token + allowlists are env-only in Hermes (no config keys).
# They are read from the environment we already sourced above — log presence, never values.
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || warn "TELEGRAM_BOT_TOKEN unset — Telegram gateway cannot start"
log "Telegram allowlist: users=$([ -n "${TELEGRAM_ALLOWED_USERS:-}" ] && echo set || echo unset), home_channel=$([ -n "${TELEGRAM_HOME_CHANNEL:-}" ] && echo set || echo unset)"

# Optional per-agent personality (real config key)
if [ -n "${AGENT_PERSONALITY:-}" ]; then
	hermes config set display.personality "$AGENT_PERSONALITY" \
		|| warn "display.personality config failed (continuing)"
fi

log "Starting Hermes gateway (autonomous mode)..."
while true; do
	if hermes gateway run; then
		log "Hermes exited cleanly."
		exit 0
	fi
	rc=$?
	warn "Hermes crashed (exit $rc). Respawning in 5s..."
	sleep 5
done
