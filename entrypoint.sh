#!/bin/bash
# Bootstraps a named Hermes agent and starts the gateway.
#
# Required env (cloud):  AGENT_NAME, TELEGRAM_BOT_TOKEN
# Optional env:          GEMINI_API_KEYS, GEMINI_API_KEY, HF_TOKEN,
#                        AGENT_MODEL, AGENT_PROVIDER, AGENT_PERSONALITY,
#                        TELEGRAM_BASE_URL,
#                        TELEGRAM_ALLOWED_USERS, TELEGRAM_HOME_CHANNEL
set -euo pipefail
umask 077

log() { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die() {
	echo "[entrypoint] FATAL: $*" >&2
	exit 1
}

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

# ── health server ─────────────────────────────────────────────────────────────
# Platforms inject their own PORT (Render); HF/local default to 7860.
PORT="${PORT:-7860}"

# HF/Render need a live port before anything else boots
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

# ── platform detection ────────────────────────────────────────────────────────
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

# ── agent identity ────────────────────────────────────────────────────────────
# AGENT_NAME guard: required for cloud deployments, random fallback for local
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	[ -n "${AGENT_NAME:-}" ] || die "AGENT_NAME is required on $PLATFORM. Set it via Space/Render secrets."
else
	AGENT_NAME="${AGENT_NAME:-$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])" 2>/dev/null || echo "agent-$$")}"
fi

# Normalize to lowercase so AGENT_NAME is case-insensitive (Ritesh/RITESH -> ritesh). The
# agents/ dirs and the /data/<name> scope below all use this one canonical form, so a state
# dir is never split across cases. Assert the agent exists now for a clear, early error.
AGENT_NAME="$(printf '%s' "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')"
if [ ! -d "$APP_DIR/agents/$AGENT_NAME" ]; then
	available="$(cd "$APP_DIR/agents" 2>/dev/null && for d in */; do printf '%s ' "${d%/}"; done)"
	die "unknown agent '$AGENT_NAME' — no agents/$AGENT_NAME/. Available: ${available:-<none>}"
fi
log "Agent instance: $AGENT_NAME"

HERMES_DATA="/data/${AGENT_NAME}/.hermes"
WORKSPACE_DATA="/data/${AGENT_NAME}/workspace"

command -v hermes >/dev/null 2>&1 || die "hermes binary not found"

# ── persistence ───────────────────────────────────────────────────────────────
# Scope each agent under /data/<AGENT_NAME>/ and symlink $HOME/.hermes to it.
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

# ── soul + per-agent config ───────────────────────────────────────────────────
SOUL_SRC="$APP_DIR/agents/${AGENT_NAME}/soul.md"
[ -f "$SOUL_SRC" ] || die "no soul at agents/${AGENT_NAME}/soul.md"
cp "$SOUL_SRC" "$HOME/.hermes/SOUL.md"
log "Loaded SOUL for ${AGENT_NAME}"

# Layer per-agent NON-secret overrides (TELEGRAM_BASE_URL, AGENT_PERSONALITY, ...).
# Secrets stay in repo-root .env or platform secrets — NEVER in agent.env.
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

# ── ssh access (tmate) ────────────────────────────────────────────────────────
# tmate generates its own ephemeral keys; no ssh-keygen needed.
echo "set -g mouse on" >"$HOME/.tmate.conf"
tmate -S /tmp/tmate.sock new-session -d 2>/dev/null || true
for attempt in 1 2 3 4 5; do
	SSH_URL=$(tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}' 2>/dev/null || true)
	[ -n "${SSH_URL:-}" ] && break
	sleep 1
done
log "SSH: ${SSH_URL:-tmate failed to connect}"

# ── auth: HF + gemini pool ────────────────────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
	hermes model set-provider hf --default || warn "HF provider config failed (continuing)"
fi

# Gemini key pool: parse keys FIRST, then reset+reseed ONLY when ≥1 valid key parsed — a malformed
# GEMINI_API_KEYS (e.g. a stray line-break inside a key) must never wipe a working pool. The parser
# strips raw control chars and retries once, so a line-wrapped paste still seeds. Hermes seeds ≤2 keys
# from env; the ONLY way to pool N keys is `hermes auth add` (random id per add, no dedup) — clear first.
GEMINI_ADDED=0
GEMINI_KEYS=()
GEMINI_SRC=""
if [ -n "${GEMINI_API_KEYS:-}" ]; then
	GEMINI_SRC="GEMINI_API_KEYS"
	mapfile -t GEMINI_KEYS < <(
		python3 -c '
import json, re, sys
raw = sys.argv[1]
try:
    keys = json.loads(raw)
except Exception:
    try:
        keys = json.loads(re.sub(r"[\x00-\x1f]", "", raw))
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
elif [ -n "${GEMINI_API_KEY:-}" ]; then
	GEMINI_SRC="GEMINI_API_KEY"
	GEMINI_KEYS=("$GEMINI_API_KEY")
fi

if [ "${#GEMINI_KEYS[@]}" -gt 0 ]; then
	reset_gemini_pool
	for k in "${GEMINI_KEYS[@]}"; do
		if add_gemini_key "$k"; then GEMINI_ADDED=$((GEMINI_ADDED + 1)); fi
	done
	log "Gemini pool reset and seeded with $GEMINI_ADDED key(s) from $GEMINI_SRC"
elif [ -n "$GEMINI_SRC" ]; then
	warn "$GEMINI_SRC set but 0 valid keys parsed — keeping existing pool (NOT reset)"
else
	warn "No GEMINI_API_KEYS or GEMINI_API_KEY set — Gemini pool unchanged"
fi

hermes config set credential_pool_strategies.gemini round_robin ||
	warn "Gemini round-robin strategy config failed (continuing)"

# ── hermes config ─────────────────────────────────────────────────────────────
# Default model + provider. The /data symlink shadows the baked config.yaml, so the persisted
# config starts with model='' and no provider — set both each boot. Provider MUST be explicit:
# our keys live in the auth pool (auth.json), not env, so without `provider=gemini` Hermes
# raises "No inference provider configured". Override per-agent via AGENT_MODEL/AGENT_PROVIDER.
AGENT_MODEL="${AGENT_MODEL:-gemini-flash-lite-latest}"
AGENT_PROVIDER="${AGENT_PROVIDER:-gemini}"
hermes config set model "$AGENT_MODEL" &&
	log "model -> $AGENT_MODEL" ||
	warn "model config failed (continuing)"
hermes config set provider "$AGENT_PROVIDER" &&
	log "provider -> $AGENT_PROVIDER" ||
	warn "provider config failed (continuing)"

# ── telegram config ───────────────────────────────────────────────────────────
# Telegram proxy (HF/Render block api.telegram.org). The bot client honors extra.base_url and
# routes every call — including the getUpdates long-poll — through the Cloudflare Worker.
TELEGRAM_BASE_URL="${TELEGRAM_BASE_URL:-https://hermes.22f2001388.workers.dev/bot}"
hermes config set gateway.platforms.telegram.extra.base_url "$TELEGRAM_BASE_URL" &&
	log "telegram base_url -> $TELEGRAM_BASE_URL" ||
	warn "telegram base_url config failed (continuing)"

# Re-set telegram.reactions each boot: the /data symlink shadows the baked telegram.reactions=true
# and the persisted config omits it, so HF would otherwise reply without reactions (Render, ephemeral,
# re-bakes the config each boot and keeps them on). This restores parity across platforms.
hermes config set telegram.reactions true &&
	log "telegram reactions -> enabled" ||
	warn "telegram reactions config failed (continuing)"

# On cloud, force-disable the IP-fallback transport. Hermes auto-discovers Telegram datacenter
# IPs and attaches a transport that dials api.telegram.org directly (telegram.py:1535), which
# overrides base_url and hangs where the host is blocked. Disabling it leaves a plain client that
# respects base_url. Local is untouched: it reaches api.telegram.org fine and keeps the fallback.
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	export HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true
	log "Telegram IP-fallback disabled (base_url-only routing on $PLATFORM)"

	# Source-level catch for the same bypass: rewrite hardcoded api.telegram.org refs
	# to the proxy host derived from TELEGRAM_BASE_URL (scheme + path stripped off).
	PROXY_HOST="${TELEGRAM_BASE_URL#*://}"
	PROXY_HOST="${PROXY_HOST%%/*}"
	if [ -n "$PROXY_HOST" ] && [ "$PROXY_HOST" != "api.telegram.org" ]; then
		SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.14/site-packages")
		find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
			-exec sed -i "s/api.telegram.org/$PROXY_HOST/g" {} + 2>/dev/null || true
		log "Telegram proxy (sed-patch) -> $PROXY_HOST"
	fi
fi

# Telegram bot token + allowlists are env-only in Hermes (no config keys) — log presence, never values.
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || warn "TELEGRAM_BOT_TOKEN unset — Telegram gateway cannot start"
log "Telegram allowlist: users=$([ -n "${TELEGRAM_ALLOWED_USERS:-}" ] && echo set || echo unset), home_channel=$([ -n "${TELEGRAM_HOME_CHANNEL:-}" ] && echo set || echo unset)"

# Optional per-agent personality (real config key — unlike the phantom telegram.* keys)
if [ -n "${AGENT_PERSONALITY:-}" ]; then
	hermes config set display.personality "$AGENT_PERSONALITY" ||
		warn "display.personality config failed (continuing)"
fi

# ── launch ────────────────────────────────────────────────────────────────────
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
