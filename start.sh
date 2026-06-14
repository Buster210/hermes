#!/bin/bash
set -euo pipefail

umask 0077

# ── Logging functions ──────────────────────────────────────────────────────
log() { echo "$*"; }
warn() { echo "WARN: $*" >&2; }
die() {
	echo "FATAL: $*" >&2
	exit 1
}

echo ""
echo " ╔══════════════════════════════════════════╗"
echo " ║                Hermes                    ║"
echo " ╚══════════════════════════════════════════╝"
echo ""

APP_DIR="${HERMES_APP_DIR:-/opt/hermes}"
WEBUI_REPO="${HERMES_WEBUI_REPO:-/opt/hermes-webui}"
HERMES_DATA_ROOT="${HERMES_HOME:-/opt/data}"

export AGENT_NAME="${AGENT_NAME:-primary}"
AGENT_HOME="${HERMES_DATA_ROOT}/${AGENT_NAME}"
HERMES_HOME="${AGENT_HOME}/.hermes"
WORKSPACE_HOME="${AGENT_HOME}/workspace"
WORKSPACE_LINK="/home/${AGENT_NAME}"
STARTUP_FILE="$WORKSPACE_HOME/startup.sh"
export HERMES_BACKUP_ROOT="$AGENT_HOME"

log "Agent: $AGENT_NAME"
log "State: $HERMES_HOME"

# ── Platform detection ────────────────────────────────────────────────────────
if [ -n "${SPACE_ID:-}" ]; then
	PLATFORM="hf"
elif [ -n "${RENDER:-}" ]; then
	PLATFORM="render"
else
	PLATFORM="local"
fi
log "Detected platform: $PLATFORM"

if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	export HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true
	log "Telegram IP-fallback disabled (base_url-only routing on $PLATFORM)"
fi

PUBLIC_PORT="${PORT:-7861}"
GATEWAY_API_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8765}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"

SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
export SYNC_INCLUDE_ENV="${SYNC_INCLUDE_ENV:-1}"
export BACKUP_BUCKET_NAME="${BACKUP_BUCKET_NAME:-hermes-backup}"
BACKUP_BUCKET="$BACKUP_BUCKET_NAME"
BACKUP_DATASET="${BACKUP_DATASET_NAME:-hermes-backup}"
CF_PROXY_ENV_FILE="/tmp/hermes-cloudflare-proxy.env"

export HERMES_HOME
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export API_SERVER_PORT="$GATEWAY_API_PORT"
export GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:${GATEWAY_API_PORT}}"
export TELEGRAM_WEBHOOK_PORT
export HERMES_WEBUI_PORT="$WEBUI_PORT"

# ── Unified auth: GATEWAY_TOKEN drives everything ─────────────────────
if [ -z "${API_SERVER_KEY:-}" ]; then
	if [ -n "${GATEWAY_TOKEN:-}" ]; then
		export API_SERVER_KEY="$GATEWAY_TOKEN"
	else
		API_SERVER_KEY="$("$APP_DIR/boot/gen-token.py")"
		export API_SERVER_KEY
		echo "GATEWAY_TOKEN not set - generated an ephemeral token for this boot."
	fi
fi

if [ -n "${GATEWAY_TOKEN:-}" ]; then
	export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-$GATEWAY_TOKEN}"
fi

# ── Setup state dirs ──────────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,home,plugins,webui}

if [ -d "$APP_DIR/hooks" ]; then
	cp -a "$APP_DIR/hooks/." "$HERMES_HOME/hooks/"
	echo "Gateway hooks seeded to $HERMES_HOME/hooks/."
fi

if [ -d "$HERMES_HOME/logs" ]; then
	for f in "$HERMES_HOME/logs"/*.log; do
		[ -f "$f" ] || continue
		sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
		if [ "$sz" -gt 5242880 ]; then
			mv -f "$f" "${f}.1"
			: >"$f"
			echo "rotated $(basename "$f") ($sz bytes -> .1)"
		fi
	done
fi

mkdir -p "$HERMES_HOME/.local/bin"
ln -sfn /opt/hermes/.venv/bin/hermes "$HERMES_HOME/.local/bin/hermes"

if mkdir -p "$(dirname "$WORKSPACE_LINK")" 2>/dev/null \
	&& { [ -L "$WORKSPACE_LINK" ] || [ ! -e "$WORKSPACE_LINK" ]; } \
	&& ln -sfn "$AGENT_HOME" "$WORKSPACE_LINK" 2>/dev/null; then
	export HOME="$WORKSPACE_LINK"
	log "Home: $HOME -> $AGENT_HOME"
	if [ "$HERMES_DATA_ROOT" != "$AGENT_HOME" ]; then
		printf '%s\n' \
			'# hermes: re-home login shells to the per-agent friendly home' \
			'[ -d "/home/${AGENT_NAME:-primary}" ] && export HOME="/home/${AGENT_NAME:-primary}"' \
			> "$HERMES_DATA_ROOT/.zshenv" 2>/dev/null || true
		printf '%s\n' \
			'# hermes: re-home login shells to the per-agent friendly home' \
			'if [ -d "/home/${AGENT_NAME:-primary}" ]; then' \
			'  export HOME="/home/${AGENT_NAME:-primary}"' \
			'  [ -f "$HOME/.profile" ] && . "$HOME/.profile"' \
			'fi' \
			> "$HERMES_DATA_ROOT/.profile" 2>/dev/null || true
	fi
else
	warn "could not re-home to $WORKSPACE_LINK; keeping HOME=$HOME"
fi

if [ ! -L "${HOME}/.hermes/plugins" ] && ! [ "${HOME}/.hermes" -ef "$HERMES_HOME" ]; then
	mkdir -p "${HOME}/.hermes"
	rm -rf "${HOME}/.hermes/plugins"
	ln -sfn "$HERMES_HOME/plugins" "${HOME}/.hermes/plugins"
fi

# ── Restore state from HF Storage Bucket (async, gated) ───────────────
HERMES_RESTORE_PID=""
if [ -n "${HF_TOKEN:-}" ]; then
	echo "Restoring Hermes state from HF bucket ${BACKUP_BUCKET}/${AGENT_NAME}"
	python3 "$APP_DIR/sync/hermes-sync.py" restore &
	HERMES_RESTORE_PID=$!
else
	echo "HF_TOKEN not set - bucket persistence is disabled."
fi

# ── Cloudflare proxy (optional) ──
CLOUDFLARE_WORKERS_TOKEN="${CLOUDFLARE_WORKERS_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
export CLOUDFLARE_WORKERS_TOKEN
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
	export CLOUDFLARE_PROXY_DEBUG="${CLOUDFLARE_PROXY_DEBUG:-false}"
	echo "Preparing Cloudflare Telegram proxy"
	python3 "$APP_DIR/network/cloudflare-proxy-setup.py" || true
	if [ -f "$CF_PROXY_ENV_FILE" ]; then
		. "$CF_PROXY_ENV_FILE"
	fi
fi

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
	echo "Preparing Cloudflare Keepalive worker"
	python3 "$APP_DIR/network/cloudflare-keepalive-setup.py" || true
fi

if [ -n "$HERMES_RESTORE_PID" ]; then
	wait "$HERMES_RESTORE_PID" || true
	echo "HF restore complete."
fi

if [ -d "$HERMES_HOME/workspace" ] && [ ! -e "$WORKSPACE_HOME" ]; then
	mv "$HERMES_HOME/workspace" "$WORKSPACE_HOME" \
		&& log "Migrated workspace -> $WORKSPACE_HOME" \
		|| log "WARN: workspace migration failed; data left at $HERMES_HOME/workspace"
fi
[ -d "$HERMES_HOME/workspace" ] || mkdir -p "$WORKSPACE_HOME"

# ── Memory-OS: seed consolidation skill + cron job (additive, idempotent) ──
if [ -d "$APP_DIR/skills" ]; then
	cp -a "$APP_DIR/skills/." "$HERMES_HOME/skills/"
	echo "Assistant skills seeded to $HERMES_HOME/skills/."
fi
mkdir -p "$HERMES_HOME/memories/longterm" "$HERMES_HOME/memories/.backups"
if [ ! -f "$HERMES_HOME/memories/.backups/initial-seed.done" ]; then
	for mf in MEMORY.md USER.md; do
		[ -f "$HERMES_HOME/memories/$mf" ] && cp -a "$HERMES_HOME/memories/$mf" "$HERMES_HOME/memories/.backups/$mf.initial" || true
	done
	touch "$HERMES_HOME/memories/.backups/initial-seed.done"
fi
HERMES_BIN="/opt/hermes/.venv/bin/hermes"
if [ -x "$HERMES_BIN" ]; then
	cron_jobs="$("$HERMES_BIN" cron list --all 2>/dev/null || true)"
	if printf '%s\n' "$cron_jobs" | grep -q "memory-os-consolidation"; then
		echo "memory-os cron job already present."
	elif "$HERMES_BIN" cron create "every 360m" \
		"Run the memory-os consolidation pass now. Load and follow the memory-os skill end to end: back up memory, read new sessions from state.db since the watermark, distill durable facts, append them to the long-term archive, then refresh MEMORY.md and USER.md within their char caps. Additive and lossless; never delete existing memory; never store secrets or PII." \
		--name "memory-os-consolidation" \
		--deliver local \
		--skill memory-os >/dev/null 2>&1; then
		echo "memory-os cron job registered (every 360m)."
	else
		echo "memory-os cron registration skipped (non-fatal)."
	fi
fi

# ── Taste capture: seed preferences hook + skill + cron job (additive) ──
for tf in TASTE-ledger.md TASTE-signals.md; do
	[ -f "$HERMES_HOME/memories/longterm/$tf" ] || : >"$HERMES_HOME/memories/longterm/$tf"
done
if [ -x "$HERMES_BIN" ]; then
	taste_jobs="$("$HERMES_BIN" cron list --all 2>/dev/null || true)"
	if printf '%s\n' "$taste_jobs" | grep -q "taste-capture"; then
		echo "taste-capture cron job already present."
	elif "$HERMES_BIN" cron create "every 730m" \
		"Run the taste-capture consolidation pass now. Load and follow the taste-capture skill end to end: read the queued correction signals (fall back to recent sessions if empty), distill durable confidence-gated preferences, append them with provenance to the long-term taste ledger, then refresh only the marked taste block in USER.md within its char cap. Additive and lossless; preserve all non-taste memory; never store secrets or PII; shape output, never erase personality." \
		--name "taste-capture" \
		--deliver local \
		--skill taste-capture >/dev/null 2>&1; then
		echo "taste-capture cron job registered (every 730m)."
	else
		echo "taste-capture cron registration skipped (non-fatal)."
	fi
fi

# ── Telegram env normalisation (aliases + webhook URL + secret) ───────
if [ -n "${TELEGRAM_USER_IDS:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
	export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_IDS"
elif [ -n "${TELEGRAM_USER_ID:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
	export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_ID"
fi

# ── Telegram home channel auto-seed ───────────────────────────────────
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	HERMES_ENV_FILE="$HERMES_HOME/.env"
	if [ -f "$HERMES_ENV_FILE" ] && grep -q '^TELEGRAM_HOME_CHANNEL=' "$HERMES_ENV_FILE"; then
		:
	else
		TG_HOME="${TELEGRAM_HOME_CHANNEL:-}"
		if [ -z "$TG_HOME" ] && [ -n "${TELEGRAM_ALLOWED_USERS:-}" ]; then
			TG_HOME="${TELEGRAM_ALLOWED_USERS%%,*}"
		fi
		TG_HOME="$(printf '%s' "$TG_HOME" | tr -d '[:space:]')"
		if [ -n "$TG_HOME" ]; then
			touch "$HERMES_ENV_FILE"
			chmod 600 "$HERMES_ENV_FILE"
			[ -s "$HERMES_ENV_FILE" ] && [ -n "$(tail -c1 "$HERMES_ENV_FILE")" ] && printf '\n' >>"$HERMES_ENV_FILE"
			printf 'TELEGRAM_HOME_CHANNEL=%s\n' "$TG_HOME" >>"$HERMES_ENV_FILE"
			export TELEGRAM_HOME_CHANNEL="$TG_HOME"
			echo "Telegram home channel seeded to $TG_HOME (run /sethome in another chat to change)."
		fi
	fi
fi

if [ "${TELEGRAM_MODE:-}" = "polling" ] && [ -n "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	log "TELEGRAM_MODE=polling — ignoring TELEGRAM_WEBHOOK_URL"
	unset TELEGRAM_WEBHOOK_URL
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${SPACE_HOST:-}" ] && [ -z "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	if [ "${TELEGRAM_MODE:-webhook}" != "polling" ]; then
		export TELEGRAM_WEBHOOK_URL="https://${SPACE_HOST}/telegram"
	fi
fi

if [ -n "${TELEGRAM_WEBHOOK_URL:-}" ] && [ -z "${TELEGRAM_WEBHOOK_SECRET:-}" ]; then
	SECRET_FILE="$HERMES_HOME/.hermes-telegram-webhook-secret"
	if [ -f "$SECRET_FILE" ]; then
		TELEGRAM_WEBHOOK_SECRET="$(cat "$SECRET_FILE")"
	else
		TELEGRAM_WEBHOOK_SECRET="$("$APP_DIR/boot/gen-webhook-secret.py")"
		printf '%s' "$TELEGRAM_WEBHOOK_SECRET" >"$SECRET_FILE"
		chmod 600 "$SECRET_FILE"
	fi
	export TELEGRAM_WEBHOOK_SECRET
fi

# ── Provider-prefix mapping (Hermes convention) ───────────────────
MODEL_INPUT="${HERMES_MODEL:-${LLM_MODEL:-}}"
MODEL_FOR_CONFIG="$MODEL_INPUT"
PROVIDER_FOR_CONFIG="${HERMES_INFERENCE_PROVIDER:-auto}"
LLM_API_KEY="${LLM_API_KEY:-}"

if [ -n "$MODEL_INPUT" ]; then
	MODEL_PREFIX="${MODEL_INPUT%%/*}"
else
	MODEL_PREFIX=""
fi

case "$MODEL_PREFIX" in
openrouter)
	[ -n "$LLM_API_KEY" ] && export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="openrouter"
	MODEL_FOR_CONFIG="${MODEL_INPUT#openrouter/}"
	;;
huggingface | hf)
	[ -n "$LLM_API_KEY" ] && export HF_TOKEN="${HF_TOKEN:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="huggingface"
	MODEL_FOR_CONFIG="${MODEL_INPUT#huggingface/}"
	;;
vercel-ai-gateway | ai-gateway)
	[ -n "$LLM_API_KEY" ] && export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="ai-gateway"
	MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
	;;
google | gemini)
	[ -n "$LLM_API_KEY" ] && export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}" GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
	PROVIDER_FOR_CONFIG="gemini"
	MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
	;;
esac

[ -n "$MODEL_PREFIX" ] && {
SIMPLE_PROVIDER_MAP="\
anthropic:ANTHROPIC_API_KEY \
openai|openai-codex:OPENAI_API_KEY \
deepseek:DEEPSEEK_API_KEY \
kimi-coding|moonshot:KIMI_API_KEY \
kimi-coding-cn|moonshot-cn|kimi-cn:KIMI_CN_API_KEY \
minimax:MINIMAX_API_KEY \
minimax-cn:MINIMAX_CN_API_KEY \
xiaomi:XIAOMI_API_KEY \
zai|z-ai|z.ai|glm:GLM_API_KEY \
arcee|arcee-ai|arceeai:ARCEEAI_API_KEY \
gmi|gmi-cloud|gmicloud:GMI_API_KEY \
alibaba|alibaba-coding-plan|alibaba_coding:DASHSCOPE_API_KEY \
tencent-tokenhub|tencent|tokenhub|tencentmaas:TOKENHUB_API_KEY \
nvidia:NVIDIA_API_KEY \
xai|grok:XAI_API_KEY \
groq|groq-cloud:GROQ_API_KEY \
opencode:OPENCODE_API_KEY \
kilocode:KILOCODE_API_KEY \
opencode-zen:OPENCODE_ZEN_API_KEY \
opencode-go:OPENCODE_GO_API_KEY \
ollama-cloud|ollama:OLLAMA_API_KEY"
for _sp in $SIMPLE_PROVIDER_MAP; do
	_sp_patterns="${_sp%%:*}" _sp_var="${_sp##*:}"
	case "$MODEL_PREFIX" in ($_sp_patterns)
		[ -n "$LLM_API_KEY" ] && export "$_sp_var=${!_sp_var:-$LLM_API_KEY}"
		break ;;
	esac
done
unset _sp _sp_patterns _sp_var SIMPLE_PROVIDER_MAP
}

if [ -n "${CUSTOM_BASE_URL:-}" ]; then
	PROVIDER_FOR_CONFIG="${CUSTOM_PROVIDER:-custom}"
	[ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
fi

export MODEL_FOR_CONFIG PROVIDER_FOR_CONFIG
export CUSTOM_BASE_URL="${CUSTOM_BASE_URL:-}"
export CUSTOM_API_KEY="${CUSTOM_API_KEY:-${LLM_API_KEY:-}}"
export CUSTOM_MODEL_CONTEXT_LENGTH="${CUSTOM_MODEL_CONTEXT_LENGTH:-131072}"
export CUSTOM_MODEL_MAX_TOKENS="${CUSTOM_MODEL_MAX_TOKENS:-8192}"
export TELEGRAM_BASE_URL="${TELEGRAM_BASE_URL:-}"
export TELEGRAM_BASE_FILE_URL="${TELEGRAM_BASE_FILE_URL:-}"

if [ -n "${CLOUDFLARE_PROXY_URL:-}" ] && [ -z "$TELEGRAM_BASE_URL" ]; then
	CLOUDFLARE_PROXY_URL="${CLOUDFLARE_PROXY_URL%/}"
	export TELEGRAM_BASE_URL="${CLOUDFLARE_PROXY_URL}/bot"
	export TELEGRAM_BASE_FILE_URL="${CLOUDFLARE_PROXY_URL}/file/bot"
fi

# ── Shell capture wrappers ─────────────────────────────────────────────────
if [ ! -f "$STARTUP_FILE" ]; then
	mkdir -p "$WORKSPACE_HOME"
	touch "$STARTUP_FILE"
	chmod +x "$STARTUP_FILE"
	echo "Created workspace/startup.sh"
fi
cp "$APP_DIR/shell/bashrc-capture.sh" "$HOME/.bashrc"
printf 'STARTUP_FILE=%q\n' "$STARTUP_FILE" >> "$HOME/.bashrc"
cat > "$HOME/.profile" << 'PROFILE'
[ -n "${BASH_VERSION:-}" ] && [ -f ~/.bashrc ] && . ~/.bashrc
PROFILE
echo "Shell capture wrappers ready."

# ── zsh interactive config (oh-my-zsh + powerlevel10k + private dotfiles) ──────
if [ -f "$HERMES_HOME/p10k.zsh" ]; then
	cp -f "$HERMES_HOME/p10k.zsh" "$HOME/.p10k.zsh"
fi

{
	printf 'HISTFILE=%q\n' "$HERMES_HOME/.zsh_history"
	printf 'HERMES_PERSONAL_ZSHRC=%q\n' "$HERMES_HOME/zshrc"
} > "$HOME/.zshrc"
cat "$APP_DIR/shell/zshrc-capture.zsh" >> "$HOME/.zshrc"
printf 'STARTUP_FILE=%q\n' "$STARTUP_FILE" >> "$HOME/.zshrc"
echo "zsh interactive config ready ($HOME/.zshrc)."

# ── Pool key promotion ──
promote_first_pool_key() {
	local singular_var="$1"
	local pool_var="$2"
	local singular_val="${!singular_var:-}"
	local pool_val="${!pool_var:-}"
	[ -n "$singular_val" ] && return 0
	[ -n "$pool_val" ] || return 0
	local last
	last=$(printf '%s' "$pool_val" \
		| sed -e 's/^[[:space:]]*\[//' -e 's/\][[:space:]]*$//' \
		| tr ',' '\n' \
		| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		| awk 'NF{last=$0} END{if(last!="") print last}' \
		| sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
	[ -n "$last" ] || return 0
	export "${singular_var}=$last"
}

for _pk_pair in \
	"OPENROUTER:OPENROUTER" "ANTHROPIC:ANTHROPIC" "OPENAI:OPENAI" \
	"GOOGLE:GOOGLE" "DEEPSEEK:DEEPSEEK" "KIMI:KIMI" \
	"MINIMAX:MINIMAX" "NVIDIA:NVIDIA" "XAI:XAI" \
	"KILOCODE:KILOCODE" "GLM:GLM" "ARCEEAI:ARCEEAI" \
	"DASHSCOPE:DASHSCOPE" "GMI:GMI" "GROQ:GROQ" \
	"TOKENHUB:TOKENHUB" "OLLAMA:OLLAMA" "OPENCODE:OPENCODE" \
	"CLAUDE_CODE_OAUTH_TOKEN:CLAUDE_CODE_OAUTH_TOKEN"; do
	_pk_s="${_pk_pair%%:*}_API_KEY"; _pk_p="${_pk_pair##*:}_API_KEYS"
	[ "$_pk_pair" = "CLAUDE_CODE_OAUTH_TOKEN:CLAUDE_CODE_OAUTH_TOKEN" ] && _pk_p="CLAUDE_CODE_OAUTH_TOKENS"
	promote_first_pool_key "$_pk_s" "$_pk_p"
done
unset _pk_pair _pk_s _pk_p

# ── Coding-agent CLIs (claude-code + opencode) headless setup ───────────────
setup_coding_agents() {
	local oc_model="${CODING_AGENT_OPENCODE_MODEL:-opencode/mimo-v2.5-free}"
	CODING_HOME="$HOME" OC_MODEL="$oc_model" "$APP_DIR/boot/setup-coding-agents.py" \
		|| echo "coding-agent setup: skipped (python error)"
}
setup_coding_agents

# ── Claude Code plugin marketplaces: re-add missing clones at boot ────────────
restore_claude_marketplaces() {
	command -v claude >/dev/null 2>&1 || return 0
	local km="$HOME/.claude/plugins/known_marketplaces.json"
	[ -f "$km" ] || return 0
	export CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1
	local src
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		if claude plugin marketplace add "$src" >/dev/null 2>&1; then
			log "Re-added Claude marketplace: $src"
		else
			warn "Claude marketplace re-add failed: $src"
		fi
	done < <("$APP_DIR/boot/restore-marketplaces.py" "$km" "$HOME/.claude/plugins/marketplaces")
}
restore_claude_marketplaces

# ── Hermes config setup (via CLI, not YAML) ───────────────────────────────
log "Configuring Hermes via CLI"

# ── hermes update on rerun (every boot after the first) ───────────────
if "$APP_DIR/boot/is-first-run.py"; then
	log "Re-run detected — running hermes update"
	hermes update >/dev/null 2>&1 || warn "hermes update failed (continuing)"
fi

# ── Idempotent API-key sync (pools + singular provider keys) ────────────────
log "Syncing API keys (idempotent)"
python3 "$APP_DIR/sync/keys-sync.py" || warn "key sync failed (continuing)"

# ── Set model + provider via CLI (more reliable than YAML) ───────────────────
hermes config set model "$MODEL_FOR_CONFIG" &&
	log "✓ Model: $MODEL_FOR_CONFIG" ||
	warn "Failed to set model (continuing)"

hermes config set provider "$PROVIDER_FOR_CONFIG" &&
	log "✓ Provider: $PROVIDER_FOR_CONFIG" ||
	warn "Failed to set provider (continuing)"

# ── Custom endpoint support ────────────────────────────────────────────────────
if [ -n "${CUSTOM_BASE_URL:-}" ]; then
	hermes config set model.base_url "${CUSTOM_BASE_URL}" &&
		log "✓ Custom base_url: $CUSTOM_BASE_URL" ||
		warn "Failed to set custom base_url"

	[ -n "${CUSTOM_API_KEY:-}" ] &&
		hermes config set model.api_key "${CUSTOM_API_KEY}" 2>/dev/null || true
fi

# ── Terminal/workspace ────────────────────────────────────────────────────────
mkdir -p "$WORKSPACE_HOME"
if [ -e "$WORKSPACE_LINK" ] && [ ! -L "$WORKSPACE_LINK" ]; then
	warn "$WORKSPACE_LINK exists as a real path; using $WORKSPACE_HOME"
	AGENT_WORKSPACE="$WORKSPACE_HOME"
else
	if mkdir -p "$(dirname "$WORKSPACE_LINK")" 2>/dev/null \
		&& ln -sfn "$AGENT_HOME" "$WORKSPACE_LINK" 2>/dev/null; then
		AGENT_WORKSPACE="$WORKSPACE_LINK/workspace"
	else
		warn "could not create $WORKSPACE_LINK (permission?); using $WORKSPACE_HOME"
		AGENT_WORKSPACE="$WORKSPACE_HOME"
	fi
fi
export TMATE_CWD="$AGENT_WORKSPACE"
hermes config set terminal.cwd "$AGENT_WORKSPACE" 2>/dev/null || true
TMUX_CONF="$HOME/.tmux.conf"
if ! grep -qxF 'set -g mouse on' "$TMUX_CONF" 2>/dev/null; then
	cat >> "$TMUX_CONF" <<'TMUXCONF'
set -g mouse on
bind c new-window -c "#{pane_current_path}"
bind '"' split-window -v -c "#{pane_current_path}"
bind % split-window -h -c "#{pane_current_path}"
TMUXCONF
fi
hermes config set compression.enabled true 2>/dev/null || true
hermes config set security.redact_secrets true 2>/dev/null || true
hermes config set display.background_process_notifications "${HERMES_BACKGROUND_NOTIFICATIONS:-result}" 2>/dev/null || true

# ── Telegram platform config (augments CLI-written config.yaml) ───────────────
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	log "Configuring Telegram platform"
	"$APP_DIR/boot/configure-telegram.py"
fi

hermes config set telegram.reactions true &&
	log "✓ Telegram reactions enabled" ||
	warn "Failed to set telegram.reactions (continuing)"

if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	if [ -n "${TELEGRAM_BASE_URL:-}" ]; then
		PROXY_HOST="${TELEGRAM_BASE_URL#*://}"
		PROXY_HOST="${PROXY_HOST%%/*}"
		if [ -n "$PROXY_HOST" ] && [ "$PROXY_HOST" != "api.telegram.org" ]; then
			SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.14/site-packages")
			find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
				-exec sed -i "s/api.telegram.org/$PROXY_HOST/g" {} + 2>/dev/null || true
			log "✓ Telegram proxy (sed-patch) -> $PROXY_HOST"
		fi
	fi

	TG_FILE=$(python3 -c "import gateway.platforms.telegram as t; print(t.__file__)" 2>/dev/null || true)
	if [ -n "$TG_FILE" ] && [ -f "$TG_FILE" ]; then
		sed -i \
			-e 's/from telegram.error import NetworkError, TimedOut$/from telegram.error import NetworkError, TimedOut, InvalidToken/' \
			-e 's/except (NetworkError, TimedOut, OSError) as init_err:/except (NetworkError, TimedOut, OSError, InvalidToken) as init_err:/' \
			"$TG_FILE" 2>/dev/null &&
			log "✓ Telegram connect-retry hardened (sed-patch: retry InvalidToken)" ||
			warn "Failed to harden Telegram connect-retry (continuing)"
	fi

	export HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT="${HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT:-180}"
	log "✓ Telegram connect timeout -> ${HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT}s"
fi

# ── Polling mode: clear any stale webhook so getUpdates can take over ──────────
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	if [ -z "${TELEGRAM_BASE_URL:-}" ] && { [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; }; then
		warn "Polling on $PLATFORM without a Telegram proxy (set CLOUDFLARE_PROXY_URL or TELEGRAM_BASE_URL) — outbound api.telegram.org is blocked; getUpdates will hang"
	else
		TELEGRAM_API_BASE="${TELEGRAM_BASE_URL:-https://api.telegram.org/bot}" \
			"$APP_DIR/boot/clear-webhook.py" && log "Telegram webhook cleared (polling mode)" || warn "deleteWebhook failed (continuing; polling may 409 if a webhook is still registered)"
	fi
fi

# ── SSH Debug Access (tmate) ──────────────────────────────────────────────────
if command -v tmate >/dev/null 2>&1 && command -v tmate-new >/dev/null 2>&1; then
	echo "set -g mouse off" >"$HOME/.tmate.conf"
	SSH_URL=$(tmate-new boot 2>/dev/null | sed -n 's/^ssh:[[:space:]]*//p') || true
	[ -n "${SSH_URL:-}" ] && log "SSH access: $SSH_URL" || log "tmate unavailable for SSH debugging"
fi

# ── Startup summary ────────────────────────────────────────────────────────────
log ""
log "╔════════════════════════════════════════════════════════════════╗"
log "║  Summary                                                       ║"
log "╚════════════════════════════════════════════════════════════════╝"
log "Primary UI : ${PRIMARY_UI:-webui}"
log "Model      : ${MODEL_FOR_CONFIG:-unset}"
log "Provider   : ${PROVIDER_FOR_CONFIG:-unset}"
log "Agent      : $AGENT_NAME"
log ""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	log "Telegram   : enabled"
else
	log "Telegram   : not configured"
fi
[ -n "${HF_TOKEN:-}" ] &&
	log "Backup     : enabled (bucket ${BACKUP_BUCKET:-hermes-backup}/${AGENT_NAME})" ||
	log "Backup     : disabled"
[ -n "${CLOUDFLARE_PROXY_URL:-}" ] &&
	log "CF Proxy   : ${CLOUDFLARE_PROXY_URL}"
log ""
log "Router     : 0.0.0.0:${PUBLIC_PORT}"
log "WebUI      : 127.0.0.1:${WEBUI_PORT}"
log "Gateway    : 127.0.0.1:${GATEWAY_API_PORT}"
log "Dashboard  : 127.0.0.1:${DASHBOARD_PORT}"
log ""

# ── Process launchers ─────────────────────────────────────────────────
start_health() {
	node "$APP_DIR/server/health-server.js" &
	HEALTH_PID=$!
}

start_dashboard() {
	echo "Launching Hermes dashboard on 127.0.0.1:${DASHBOARD_PORT}"
	(hermes dashboard --host 127.0.0.1 --insecure 2>&1 | tee -a "$HERMES_HOME/logs/dashboard.log") &
	DASHBOARD_PID=$!
}

start_gateway() {
	echo "Launching Hermes gateway"
	(hermes gateway run 2>&1 | tee -a "$HERMES_HOME/logs/gateway.log") &
	GATEWAY_PID=$!
}

start_webui() {
	echo "Launching Hermes WebUI on 127.0.0.1:${WEBUI_PORT}"
	(cd "$WEBUI_REPO" &&
		"$HERMES_WEBUI_PYTHON" "$WEBUI_REPO/server.py" 2>&1 |
		tee -a "$HERMES_HOME/logs/webui.log") &
	WEBUI_PID=$!
}

SYNC_LOOP_PID=""
start_sync_loop() {
	[ -n "${HF_TOKEN:-}" ] || return 0
	if [ -n "${SYNC_LOOP_PID:-}" ] && kill -0 "$SYNC_LOOP_PID" 2>/dev/null; then
		return 0
	fi
	python3 -u "$APP_DIR/sync/hermes-sync.py" loop &
	SYNC_LOOP_PID=$!
}

sync_now() {
	[ -n "${HF_TOKEN:-}" ] || return 0
	python3 "$APP_DIR/sync/hermes-sync.py" sync-once || echo "Warning: state sync failed."
}

wait_port_ready() {
	local port="$1" timeout="$2" pid="$3" i
	for ((i = 0; i < timeout; i++)); do
		if (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		sleep 1
	done
	return 1
}

kill_tree() {
	local pid="$1" child
	[ -n "$pid" ] || return 0
	if [ -r "/proc/$pid/task/$pid/children" ]; then
		for child in $(cat "/proc/$pid/task/$pid/children" 2>/dev/null); do
			kill_tree "$child"
		done
	fi
	kill -TERM "$pid" 2>/dev/null || true
}

# ── Graceful shutdown ─────────────────────────────────────────────────
graceful_shutdown() {
	trap '' SIGTERM SIGINT
	echo "Shutting down"
	sync_now
	for pid in "${WEBUI_PID:-}" "${GATEWAY_PID:-}" "${DASHBOARD_PID:-}" "${HEALTH_PID:-}" "${SYNC_LOOP_PID:-}"; do
		kill_tree "$pid"
	done
	kill $(jobs -p) 2>/dev/null || true
	exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── WebUI runtime env (static; exported once) ─────────────────────────
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_PYTHON="/opt/hermes/.venv/bin/python"
export HERMES_WEBUI_HOST="127.0.0.1"
export HERMES_WEBUI_PORT
export HERMES_WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-$HERMES_HOME/webui}"
export HERMES_WEBUI_DEFAULT_WORKSPACE="${HERMES_WEBUI_DEFAULT_WORKSPACE:-$WORKSPACE_HOME}"
export HERMES_WEBUI_AUTO_INSTALL="0"
mkdir -p "$HERMES_WEBUI_STATE_DIR"

GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-90}"
WEBUI_READY_TIMEOUT="${WEBUI_READY_TIMEOUT:-60}"

# ── Initial boot ──────────────────────────────────────────────────────
start_health

if [ -n "${WEBHOOK_URL:-}" ]; then
	"$APP_DIR/boot/notify-webhook.py" >/dev/null 2>&1 &
fi


# ── Run workspace startup script ──
if [ -s "$STARTUP_FILE" ]; then
	echo "Running workspace/startup.sh..."
	set +e
	HERMES_CAPTURE_DISABLE=1 bash -l "$STARTUP_FILE"
	set -e
	echo "Workspace startup script complete."
fi

start_dashboard

start_gateway
start_webui

if ! wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
	echo ""
	echo "Hermes gateway failed to expose the API health port. Last 40 log lines:"
	echo "----------------------------------------"
	tail -40 "$HERMES_HOME/logs/gateway.log" || true
	exit 1
fi

if [ -z "$MODEL_FOR_CONFIG" ]; then
	die "CRITICAL: No model configured. Ensure LLM_MODEL is set."
fi
log "✓ Model configured: $MODEL_FOR_CONFIG"

start_sync_loop

if wait_port_ready "$WEBUI_PORT" "$WEBUI_READY_TIMEOUT" "$WEBUI_PID"; then
	echo "Hermes WebUI is up."
else
	echo "Warning: Hermes WebUI not ready within ${WEBUI_READY_TIMEOUT}s. Last 20 log lines:"
	tail -20 "$HERMES_HOME/logs/webui.log" || true
fi

# ── Service restart loop (self-healing) ───────────────────────────────────────
SUPERVISOR_POLL_INTERVAL="${SUPERVISOR_POLL_INTERVAL:-10}"
SUPERVISOR_MAX_RESTARTS="${SUPERVISOR_MAX_RESTARTS:-0}"
GATEWAY_RESTART_COUNT=0

supervisor_check() {
	local name="$1" pid_var="$2" restart_fn="$3" port="${4:-}" port_timeout="${5:-}"
	local pid="${!pid_var:-}"
	[ -n "$pid" ] || return 0
	kill -0 "$pid" 2>/dev/null && return 0
	warn "Hermes $name died (PID $pid). Respawning in 5s"
	sleep 5
	"$restart_fn"
	if [ -n "$port" ] && [ -n "$port_timeout" ]; then
		if wait_port_ready "$port" "$port_timeout" "${!pid_var}"; then
			log "$name restarted successfully"
		else
			warn "$name failed to restart — continuing anyway"
		fi
	fi
	sync_now
}

log "Starting service monitor loop (restart on crash)"

while true; do
	sleep "$SUPERVISOR_POLL_INTERVAL"

	if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
		if [ "$SUPERVISOR_MAX_RESTARTS" != "0" ] && [ "$GATEWAY_RESTART_COUNT" -ge "$SUPERVISOR_MAX_RESTARTS" ]; then
			warn "Hermes gateway exceeded SUPERVISOR_MAX_RESTARTS ($SUPERVISOR_MAX_RESTARTS) — syncing and exiting for a clean restart"
			sync_now
			exit 1
		fi
		GATEWAY_RESTART_COUNT=$((GATEWAY_RESTART_COUNT + 1))
		warn "Hermes gateway died (PID $GATEWAY_PID). Respawning in 5s (restart $GATEWAY_RESTART_COUNT)"
		sleep 5
		start_gateway
		if wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
			log "Gateway restarted successfully"
		else
			warn "Gateway failed to restart — continuing anyway"
		fi
		sync_now
	fi

	supervisor_check "WebUI"          WEBUI_PID    start_webui    "$WEBUI_PORT"     "$WEBUI_READY_TIMEOUT"
	supervisor_check "health server"  HEALTH_PID   start_health
	supervisor_check "dashboard"      DASHBOARD_PID start_dashboard

	if [ -n "${HF_TOKEN:-}" ] && { [ -z "${SYNC_LOOP_PID:-}" ] || ! kill -0 "$SYNC_LOOP_PID" 2>/dev/null; }; then
		warn "Backup sync loop died. Respawning"
		SYNC_LOOP_PID=""
		start_sync_loop
	fi
done
