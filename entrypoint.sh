#!/bin/bash
set -euo pipefail
umask 077

echo "Initializing Hermes Agent..."

# Paths
PERSIST_DIR="/data"
HERMES_DATA="/data/.hermes"
WORKSPACE_DATA="/data/workspace"

# Verify hermes binary exists
command -v hermes >/dev/null 2>&1 || {
	echo "hermes binary not found"
	exit 1
}

# Persistent storage setup
if [ -d "$PERSIST_DIR" ]; then
	echo "Persistent storage found at $PERSIST_DIR"
	mkdir -p "$HERMES_DATA" "$WORKSPACE_DATA"
	if [ ! -L "$HOME/.hermes" ]; then
		rm -rf "$HOME/.hermes"
		ln -s "$HERMES_DATA" "$HOME/.hermes"
	fi
	cd "$WORKSPACE_DATA"
else
	echo "No /data found -- running on ephemeral storage"
	mkdir -p "$HOME/.hermes"
	cd "$HOME/app"
fi

# Write and source credentials
ENV_FILE="$HOME/.hermes/.env"
if [ -f ".env" ]; then
	cp .env "$ENV_FILE"
	echo "Credentials loaded from .env file"
else
	cat <<EOF >"$ENV_FILE"
HF_TOKEN=${HF_TOKEN:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
GEMINI_API_KEY_1=${GEMINI_API_KEY_1:-}
GEMINI_API_KEY_2=${GEMINI_API_KEY_2:-}
GEMINI_API_KEY_3=${GEMINI_API_KEY_3:-}
GEMINI_API_KEY_4=${GEMINI_API_KEY_4:-}
GATEWAY_ALLOW_ALL_USERS=true
EOF
	echo "Credentials loaded from environment variables"
fi
chmod 600 "$ENV_FILE"
set -a && source "$ENV_FILE" && set +a

# Configure Hermes — failures are non-fatal so startup isn't blocked
if [ -n "${HF_TOKEN:-}" ]; then
	hermes model set-provider hf --default || echo "Warning: HF provider config failed (continue)"
fi
hermes config set providers.gemini.credentials \
	'[{"env":"GEMINI_API_KEY"},{"env":"GEMINI_API_KEY_1"},{"env":"GEMINI_API_KEY_2"},{"env":"GEMINI_API_KEY_3"},{"env":"GEMINI_API_KEY_4"}]' ||
	echo "Warning: Gemini credentials config failed (continue)"
hermes config set providers.gemini.strategy round-robin ||
	echo "Warning: Gemini strategy config failed (continue)"

if [ -n "${TELEGRAM_PROXY_HOST:-}" ]; then
	SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.11/site-packages")
	find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
		-exec sed -i "s/api.telegram.org/$TELEGRAM_PROXY_HOST/g" {} + 2>/dev/null || true
	echo "Telegram proxy configured: $TELEGRAM_PROXY_HOST"
fi

# Liveness probe
python3 -m http.server 7860 &

# Self-healing gateway loop
echo "Starting Hermes gateway..."
while true; do
	if hermes gateway run; then
		echo "Hermes exited cleanly."
		exit 0
	else
		echo "Hermes crashed (exit $?). Respawning in 5s..."
		sleep 5
	fi
done
