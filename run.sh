#!/usr/bin/env bash
# Local launcher: ./run.sh <agent-name> [up|down|logs|build]
# Selects an agent from agents/<name>/, layers env (root .env then agent.env),
# and runs docker compose in a per-agent project so multiple agents don't collide.
set -euo pipefail

NAME="${1:?usage: ./run.sh <agent-name> [up|down|logs|build]}"
ACTION="${2:-up}"
AGENT_DIR="agents/${NAME}"

[ -d "$AGENT_DIR" ] || { echo "FATAL: no agent dir $AGENT_DIR" >&2; exit 1; }
[ -f "$AGENT_DIR/soul.md" ] || { echo "FATAL: missing $AGENT_DIR/soul.md" >&2; exit 1; }

export AGENT_NAME="$NAME"

# Per-agent non-secret overrides (shell-safe simple values) for compose interpolation.
# Secrets in repo-root .env are loaded by compose itself (env_file + native .env interpolation);
# we do NOT source .env here — values like the GEMINI_API_KEYS JSON list aren't shell-safe.
set -a
[ -f "$AGENT_DIR/agent.env" ] && . "$AGENT_DIR/agent.env"
set +a

PROJECT="hermes-${NAME}"

case "$ACTION" in
	up)    exec docker compose -p "$PROJECT" up --build ;;
	build) exec docker compose -p "$PROJECT" build ;;
	down)  exec docker compose -p "$PROJECT" down ;;
	logs)  exec docker compose -p "$PROJECT" logs -f ;;
	*)     echo "FATAL: unknown action '$ACTION' (use up|down|logs|build)" >&2; exit 1 ;;
esac
