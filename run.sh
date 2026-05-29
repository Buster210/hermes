#!/usr/bin/env bash
set -euo pipefail

NAME="${1:?usage: ./run.sh <agent-name> [up|down|logs|build]}"
ACTION="${2:-up}"
AGENT_DIR="agents/${NAME}"

[ -d "$AGENT_DIR" ] || {
	echo "FATAL: no agent dir $AGENT_DIR" >&2
	exit 1
}
[ -f "$AGENT_DIR/soul.md" ] || {
	echo "FATAL: missing $AGENT_DIR/soul.md" >&2
	exit 1
}

export AGENT_NAME="$NAME"

# .env loaded by compose; here only agent.env (JSON values aren't shell-safe to source).
set -a
[ -f "$AGENT_DIR/agent.env" ] && . "$AGENT_DIR/agent.env"
set +a

export CACHEBUST="$(date +%s)"

PROJECT="hermes-${NAME}"

case "$ACTION" in
up) exec docker compose -p "$PROJECT" up --build ;;
build) exec docker compose -p "$PROJECT" build ;;
down) exec docker compose -p "$PROJECT" down ;;
logs) exec docker compose -p "$PROJECT" logs -f ;;
*)
	echo "FATAL: unknown action '$ACTION' (use up|down|logs|build)" >&2
	exit 1
	;;
esac
