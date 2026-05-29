#!/bin/bash
set -euo pipefail

umask 0077

APP_DIR="${HERMES_APP_DIR:-/opt/hermes}"
WEBUI_REPO="${HERMES_WEBUI_REPO:-/opt/hermes-webui}"
HERMES_HOME="${HERMES_HOME:-/opt/data}"

PUBLIC_PORT="${PORT:-7861}"
GATEWAY_API_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8765}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"

SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
BACKUP_DATASET="${BACKUP_DATASET_NAME:-hermes-backup}"
CF_PROXY_ENV_FILE="/tmp/hermes-cloudflare-proxy.env"

export HERMES_HOME
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export API_SERVER_PORT="$GATEWAY_API_PORT"
export GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:${GATEWAY_API_PORT}}"
export TELEGRAM_WEBHOOK_PORT
export HERMES_WEBUI_PORT="$WEBUI_PORT"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  🪽 Hermes WebUI Gateway    ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Unified auth: GATEWAY_TOKEN drives everything ─────────────────────
if [ -z "${API_SERVER_KEY:-}" ]; then
  if [ -n "${GATEWAY_TOKEN:-}" ]; then
    export API_SERVER_KEY="$GATEWAY_TOKEN"
  else
    API_SERVER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
    export API_SERVER_KEY
    echo "GATEWAY_TOKEN not set - generated an ephemeral token for this boot."
  fi
fi

# Same token becomes Hermes WebUI's login password (unified auth).
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-$GATEWAY_TOKEN}"
fi

# ── Setup state dirs ──────────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home,plugins,webui}

# Rotate on-disk logs at boot. The router + WebUI + dashboard tee their
# stdout into $HERMES_HOME/logs/*.log via `tee -a`, which means without
# rotation those files grow forever and end up in the HF Dataset backup.
# Strategy: if a log is >5MB, rename to .1 (overwriting any previous .1)
# and start fresh. Cheap, deterministic, no cron needed.
if [ -d "$HERMES_HOME/logs" ]; then
  for f in "$HERMES_HOME/logs"/*.log; do
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 5242880 ]; then
      mv -f "$f" "${f}.1"
      : > "$f"
      echo "rotated $(basename "$f") ($sz bytes -> .1)"
    fi
  done
fi

# Expose hermes CLI to login shells
mkdir -p "$HERMES_HOME/.local/bin"
ln -sfn /opt/hermes/.venv/bin/hermes "$HERMES_HOME/.local/bin/hermes"

# Redirect Hermes plugin dir into volume
if [ ! -L "${HOME}/.hermes/plugins" ]; then
  mkdir -p "${HOME}/.hermes"
  rm -rf "${HOME}/.hermes/plugins"
  ln -sfn "$HERMES_HOME/plugins" "${HOME}/.hermes/plugins"
fi

# ── Restore state from HF Dataset ─────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Restoring Hermes state from HF Dataset..."
  python3 "$APP_DIR/hermes-sync.py" restore || true
else
  echo "HF_TOKEN not set - dataset persistence is disabled."
fi

# ── Cloudflare proxy (optional) ──
CLOUDFLARE_WORKERS_TOKEN="${CLOUDFLARE_WORKERS_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
export CLOUDFLARE_WORKERS_TOKEN
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  export CLOUDFLARE_PROXY_DEBUG="${CLOUDFLARE_PROXY_DEBUG:-false}"
  echo "Preparing Cloudflare Telegram proxy..."
  python3 "$APP_DIR/cloudflare-proxy-setup.py" || true
  if [ -f "$CF_PROXY_ENV_FILE" ]; then
    . "$CF_PROXY_ENV_FILE"
  fi
fi

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
  echo "Preparing Cloudflare Keepalive worker..."
  python3 "$APP_DIR/cloudflare-keepalive-setup.py" || true
fi

# ── Telegram env normalisation (aliases + webhook URL + secret) ───────
if [ -n "${TELEGRAM_USER_IDS:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
  export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_IDS"
elif [ -n "${TELEGRAM_USER_ID:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
  export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_ID"
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
    TELEGRAM_WEBHOOK_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
    printf '%s' "$TELEGRAM_WEBHOOK_SECRET" > "$SECRET_FILE"
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
  huggingface|hf)
    [ -n "$LLM_API_KEY" ] && export HF_TOKEN="${HF_TOKEN:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="huggingface"
    MODEL_FOR_CONFIG="${MODEL_INPUT#huggingface/}"
    ;;
  vercel-ai-gateway|ai-gateway)
    [ -n "$LLM_API_KEY" ] && export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="ai-gateway"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
    ;;
  anthropic)
    [ -n "$LLM_API_KEY" ] && export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$LLM_API_KEY}"
    ;;
  openai|openai-codex)
    [ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
    ;;
  google|gemini)
    [ -n "$LLM_API_KEY" ] && export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}" GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
    PROVIDER_FOR_CONFIG="gemini"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
    ;;
  deepseek)
    [ -n "$LLM_API_KEY" ] && export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding|moonshot)
    [ -n "$LLM_API_KEY" ] && export KIMI_API_KEY="${KIMI_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding-cn|moonshot-cn|kimi-cn)
    [ -n "$LLM_API_KEY" ] && export KIMI_CN_API_KEY="${KIMI_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_API_KEY="${MINIMAX_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax-cn)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_CN_API_KEY="${MINIMAX_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  xiaomi)
    [ -n "$LLM_API_KEY" ] && export XIAOMI_API_KEY="${XIAOMI_API_KEY:-$LLM_API_KEY}"
    ;;
  zai|z-ai|z.ai|glm)
    [ -n "$LLM_API_KEY" ] && export GLM_API_KEY="${GLM_API_KEY:-$LLM_API_KEY}"
    ;;
  arcee|arcee-ai|arceeai)
    [ -n "$LLM_API_KEY" ] && export ARCEEAI_API_KEY="${ARCEEAI_API_KEY:-$LLM_API_KEY}"
    ;;
  gmi|gmi-cloud|gmicloud)
    [ -n "$LLM_API_KEY" ] && export GMI_API_KEY="${GMI_API_KEY:-$LLM_API_KEY}"
    ;;
  alibaba|alibaba-coding-plan|alibaba_coding)
    [ -n "$LLM_API_KEY" ] && export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
    ;;
  tencent-tokenhub|tencent|tokenhub|tencentmaas)
    [ -n "$LLM_API_KEY" ] && export TOKENHUB_API_KEY="${TOKENHUB_API_KEY:-$LLM_API_KEY}"
    ;;
  nvidia)
    [ -n "$LLM_API_KEY" ] && export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$LLM_API_KEY}"
    ;;
  xai|grok)
    [ -n "$LLM_API_KEY" ] && export XAI_API_KEY="${XAI_API_KEY:-$LLM_API_KEY}"
    ;;
  kilocode)
    [ -n "$LLM_API_KEY" ] && export KILOCODE_API_KEY="${KILOCODE_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-zen)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-go)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY:-$LLM_API_KEY}"
    ;;
esac

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

# ── Build Hermes config.yaml ──────────────────────────────────────────
python3 - <<'PY'
import os
from pathlib import Path
import yaml

home = Path(os.environ["HERMES_HOME"])
path = home / "config.yaml"
try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
except FileNotFoundError:
    config = {}

model_name = os.environ.get("MODEL_FOR_CONFIG", "").strip()
provider_name = os.environ.get("PROVIDER_FOR_CONFIG", "").strip()

if model_name:
    model = config.setdefault("model", {})
    model["default"] = model_name
    if provider_name and provider_name != "auto":
        model["provider"] = provider_name
    else:
        model.pop("provider", None)
else:
    model = config.get("model", {})
    print("No LLM_MODEL/HERMES_MODEL set; leaving Hermes model config unchanged.")

custom_base = os.environ.get("CUSTOM_BASE_URL", "").strip()
if custom_base and model_name:
    model.setdefault("base_url", custom_base.rstrip("/"))
    if os.environ.get("CUSTOM_API_KEY"):
        model.setdefault("api_key", os.environ["CUSTOM_API_KEY"])
    try:
        model.setdefault("context_length", int(os.environ.get("CUSTOM_MODEL_CONTEXT_LENGTH", "131072")))
        model.setdefault("max_tokens", int(os.environ.get("CUSTOM_MODEL_MAX_TOKENS", "8192")))
    except ValueError:
        pass

config.setdefault("terminal", {}).setdefault("cwd", os.environ.get("MESSAGING_CWD", str(home / "workspace")))
config.setdefault("compression", {}).setdefault("enabled", True)
config.setdefault("display", {}).setdefault("background_process_notifications", os.environ.get("HERMES_BACKGROUND_NOTIFICATIONS", "result"))
config.setdefault("security", {}).setdefault("redact_secrets", True)

platforms = config.setdefault("platforms", {})

if os.environ.get("TELEGRAM_BOT_TOKEN"):
    telegram = platforms.setdefault("telegram", {})
    telegram.setdefault("enabled", True)
    extra = telegram.setdefault("extra", {})
    if os.environ.get("TELEGRAM_BASE_URL"):
        extra.setdefault("base_url", os.environ["TELEGRAM_BASE_URL"])
        extra.setdefault("base_file_url", os.environ.get("TELEGRAM_BASE_FILE_URL") or os.environ["TELEGRAM_BASE_URL"])
    if os.environ.get("TELEGRAM_ALLOWED_USERS"):
        config.setdefault("telegram", {}).setdefault("allow_from", [
            item.strip()
            for item in os.environ["TELEGRAM_ALLOWED_USERS"].split(",")
            if item.strip()
        ])

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
path.chmod(0o600)
PY

# ── Startup summary ───────────────────────────────────────────────────
echo ""
echo "Primary UI : ${PRIMARY_UI:-webui}"
echo "Model      : ${MODEL_FOR_CONFIG:-unset}"
echo "Provider   : ${PROVIDER_FOR_CONFIG:-unset}"
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "Telegram   : enabled"
else
  echo "Telegram   : not configured"
fi
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Backup     : ${BACKUP_DATASET} (poll ${SYNC_POLL_INTERVAL:-2}s, debounce ${SYNC_DEBOUNCE_SECONDS:-3}s, max ${SYNC_INTERVAL:-60}s)"
else
  echo "Backup     : disabled"
fi
if [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  echo "CF Proxy   : ${CLOUDFLARE_PROXY_URL}"
fi
echo "Router     : 0.0.0.0:${PUBLIC_PORT}"
echo "WebUI      : 127.0.0.1:${WEBUI_PORT}"
echo "Gateway    : 127.0.0.1:${GATEWAY_API_PORT}"
echo "Dashboard  : 127.0.0.1:${DASHBOARD_PORT}"
echo ""

# ── Process launchers ─────────────────────────────────────────────────
# Supervisor loop restarts dead services via these launchers.
start_health() {
  node "$APP_DIR/health-server.js" &
  HEALTH_PID=$!
}

start_dashboard() {
  echo "Launching Hermes dashboard on 127.0.0.1:${DASHBOARD_PORT}..."
  (hermes dashboard --host 127.0.0.1 --insecure 2>&1 | tee -a "$HERMES_HOME/logs/dashboard.log") &
  DASHBOARD_PID=$!
}

start_gateway() {
  echo "Launching Hermes gateway..."
  (hermes gateway run 2>&1 | tee -a "$HERMES_HOME/logs/gateway.log") &
  GATEWAY_PID=$!
}

start_webui() {
  echo "Launching Hermes WebUI on 127.0.0.1:${WEBUI_PORT}..."
  (cd "$WEBUI_REPO" && \
     "$HERMES_WEBUI_PYTHON" "$WEBUI_REPO/server.py" 2>&1 | \
     tee -a "$HERMES_HOME/logs/webui.log") &
  WEBUI_PID=$!
}

# Kept alive by supervisor; silent death = silent data loss.
SYNC_LOOP_PID=""
start_sync_loop() {
  [ -n "${HF_TOKEN:-}" ] || return 0
  if [ -n "${SYNC_LOOP_PID:-}" ] && kill -0 "$SYNC_LOOP_PID" 2>/dev/null; then
    return 0
  fi
  python3 -u "$APP_DIR/hermes-sync.py" loop &
  SYNC_LOOP_PID=$!
}

# No-op without HF_TOKEN.
sync_now() {
  [ -n "${HF_TOKEN:-}" ] || return 0
  python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: state sync failed."
}

# Returns 0 on connect or if pid dies/timeout.
wait_port_ready() {
  local port="$1" timeout="$2" pid="$3" i
  for ((i=0; i<timeout; i++)); do
    if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
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
  trap '' SIGTERM SIGINT   # ignore repeat signals so the final sync isn't interrupted
  echo "Shutting down..."
  sync_now
  for pid in "${WEBUI_PID:-}" "${GATEWAY_PID:-}" "${DASHBOARD_PID:-}" "${HEALTH_PID:-}" "${SYNC_LOOP_PID:-}"; do
    kill_tree "$pid"
  done
  kill $(jobs -p) 2>/dev/null || true
  exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── WebUI runtime env (static; exported once) ─────────────────────────
# Agent venv paths; state backed up from $HERMES_HOME/webui.
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_PYTHON="/opt/hermes/.venv/bin/python"
export HERMES_WEBUI_HOST="127.0.0.1"
export HERMES_WEBUI_PORT
export HERMES_WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-$HERMES_HOME/webui}"
export HERMES_WEBUI_DEFAULT_WORKSPACE="${HERMES_WEBUI_DEFAULT_WORKSPACE:-$HERMES_HOME/workspace}"
export HERMES_WEBUI_AUTO_INSTALL="0"
mkdir -p "$HERMES_WEBUI_STATE_DIR"

GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-120}"
WEBUI_READY_TIMEOUT="${WEBUI_READY_TIMEOUT:-60}"

# ── Initial boot ──────────────────────────────────────────────────────
start_health

if [ -n "${WEBHOOK_URL:-}" ]; then
  python3 - <<'PY' >/dev/null 2>&1 &
import json, os, urllib.request
body = json.dumps({
    "event": "restart",
    "status": "success",
    "message": "Hermes WebUI has started.",
    "model": os.environ.get("MODEL_FOR_CONFIG", ""),
}).encode()
req = urllib.request.Request(os.environ["WEBHOOK_URL"], data=body, method="POST",
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
PY
fi

# Private; no readiness gate.
start_dashboard

# Fatal on first boot; no gateway = useless container.
start_gateway
if ! wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
  echo ""
  echo "Hermes gateway failed to expose the API health port. Last 40 log lines:"
  echo "----------------------------------------"
  tail -40 "$HERMES_HOME/logs/gateway.log" || true
  exit 1
fi

# Start persistence before state mutations.
start_sync_loop

# Non-fatal; router shows it as down.
start_webui
if wait_port_ready "$WEBUI_PORT" "$WEBUI_READY_TIMEOUT" "$WEBUI_PID"; then
  echo "Hermes WebUI is up."
else
  echo "Warning: Hermes WebUI not ready within ${WEBUI_READY_TIMEOUT}s. Last 20 log lines:"
  tail -20 "$HERMES_HOME/logs/webui.log" || true
fi

# ── Supervisor loop ───────────────────────────────────────────────────
# Polls PIDs; restarts dead services; caps restarts.
SUPERVISOR_POLL_INTERVAL="${SUPERVISOR_POLL_INTERVAL:-5}"
SUPERVISOR_MAX_RESTARTS="${SUPERVISOR_MAX_RESTARTS:-0}"
HEALTH_RESTARTS=0
DASHBOARD_RESTARTS=0
GATEWAY_RESTARTS=0
WEBUI_RESTARTS=0
SYNC_RESTARTS=0

cap_reached() {  # restart_count
  [ "$SUPERVISOR_MAX_RESTARTS" != "0" ] && [ "$1" -ge "$SUPERVISOR_MAX_RESTARTS" ]
}

while true; do
  sleep "$SUPERVISOR_POLL_INTERVAL"

  if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
    HEALTH_RESTARTS=$((HEALTH_RESTARTS + 1))
    if cap_reached "$HEALTH_RESTARTS"; then
      echo "health-server hit restart cap (${SUPERVISOR_MAX_RESTARTS}); exiting for container restart."
      exit 1
    fi
    echo "Warning: health-server died; restart #${HEALTH_RESTARTS}..."
    start_health
    sync_now
  fi

  if ! kill -0 "$DASHBOARD_PID" 2>/dev/null; then
    DASHBOARD_RESTARTS=$((DASHBOARD_RESTARTS + 1))
    if cap_reached "$DASHBOARD_RESTARTS"; then
      echo "dashboard hit restart cap (${SUPERVISOR_MAX_RESTARTS}); exiting for container restart."
      exit 1
    fi
    echo "Warning: Hermes dashboard died; restart #${DASHBOARD_RESTARTS}..."
    start_dashboard
    sync_now
  fi

  if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
    GATEWAY_RESTARTS=$((GATEWAY_RESTARTS + 1))
    if cap_reached "$GATEWAY_RESTARTS"; then
      echo "gateway hit restart cap (${SUPERVISOR_MAX_RESTARTS}); exiting for container restart."
      exit 1
    fi
    echo "Warning: Hermes gateway died; restart #${GATEWAY_RESTARTS}..."
    start_gateway
    if ! wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
      echo "Warning: gateway not ready within ${GATEWAY_READY_TIMEOUT}s after restart."
    fi
    sync_now
  fi

  if ! kill -0 "$WEBUI_PID" 2>/dev/null; then
    WEBUI_RESTARTS=$((WEBUI_RESTARTS + 1))
    if cap_reached "$WEBUI_RESTARTS"; then
      echo "webui hit restart cap (${SUPERVISOR_MAX_RESTARTS}); exiting for container restart."
      exit 1
    fi
    echo "Warning: Hermes WebUI died; restart #${WEBUI_RESTARTS}..."
    start_webui
    if ! wait_port_ready "$WEBUI_PORT" "$WEBUI_READY_TIMEOUT" "$WEBUI_PID"; then
      echo "Warning: webui not ready within ${WEBUI_READY_TIMEOUT}s after restart."
    fi
    sync_now
  fi

  if [ -n "${HF_TOKEN:-}" ] && { [ -z "${SYNC_LOOP_PID:-}" ] || ! kill -0 "$SYNC_LOOP_PID" 2>/dev/null; }; then
    SYNC_RESTARTS=$((SYNC_RESTARTS + 1))
    if cap_reached "$SYNC_RESTARTS"; then
      echo "backup sync loop hit restart cap (${SUPERVISOR_MAX_RESTARTS}); exiting for container restart."
      exit 1
    fi
    echo "Warning: backup sync loop died; restart #${SYNC_RESTARTS}..."
    SYNC_LOOP_PID=""
    start_sync_loop
  fi
done
