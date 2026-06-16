#!/usr/bin/env bash
# On-demand tmate sessions for external SSH/web access.
# Symlinked as tmate-new / tmate-ls / tmate-kill, or `tmate-tools <cmd>`.
set -euo pipefail
shopt -s nullglob

TMATE_DIR="${TMATE_DIR:-/tmp/tmate}"
MAX_TMATE_SESSIONS="${MAX_TMATE_SESSIONS:-10}"
READY_TIMEOUT="${TMATE_READY_TIMEOUT:-15}"

mkdir -p "$TMATE_DIR"

_TMATE_LOG="${TMATE_LOG:-$TMATE_DIR/supervisor.log}"
_log() {
	printf '[%s] tmate-tools: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$_TMATE_LOG" >&2 || true
}

_die() {
	echo "tmate-tools: $*" >&2
	exit 1
}
command -v tmate >/dev/null 2>&1 || _die "tmate not installed"

_alive() {
	if [ -S "$1" ] && tmate -S "$1" display -p '#{session_name}' >/dev/null 2>&1; then
		return 0
	fi
	rm -f "$1" 2>/dev/null || true
	return 1
}

_name_of() { tmate -S "$1" display -p '#{session_name}' 2>/dev/null || true; }

_md2() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[][_*()~`>#+=|{}.!-]/\\&/g'; }

# Telegram notify. Returns 0 on success/skip, non-zero on delivery failure.
# TMATE_NOTIFY=0 disables. TMATE_BOOT_NO_NOTIFY=1 suppresses (used by supervise loop).
_notify() {
	[ "${TMATE_NOTIFY:-1}" = "0" ] && return 0
	[ "${TMATE_BOOT_NO_NOTIFY:-0}" = "1" ] && return 0
	command -v curl >/dev/null 2>&1 || { _log "notify: curl not found"; return 0; }
	local tok="${TELEGRAM_BOT_TOKEN:-}" chat="${TELEGRAM_HOME_CHANNEL:-}" base="${TELEGRAM_BASE_URL:-}"
	local envf="${HERMES_HOME:-/opt/data}/.env"
	if [ -f "$envf" ]; then
		[ -n "$tok" ] || tok=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$envf" | tail -1 | tr -d '"'\''\r')
		[ -n "$chat" ] || chat=$(sed -n 's/^TELEGRAM_HOME_CHANNEL=//p' "$envf" | tail -1 | tr -d '"'\''\r')
	fi
	[ -n "$tok" ] && [ -n "$chat" ] || { _log "notify: TELEGRAM_BOT_TOKEN or TELEGRAM_HOME_CHANNEL not set — skipping"; return 0; }
	local url="https://api.telegram.org/bot${tok}/sendMessage"
	[ -n "$base" ] && url="${base}${tok}/sendMessage"
	local out ec
	out=$(curl -fsS --max-time 10 -X POST "$url" \
		--data-urlencode "chat_id=${chat}" \
		--data-urlencode "parse_mode=MarkdownV2" \
		--data-urlencode "text=$1" 2>&1)
	ec=$?
	[ "$ec" -eq 0 ] && return 0
	_log "notify: curl failed (exit $ec): ${out:-no output}"
	return "$ec"
}

_socket_for() {
	local want="$1" s
	for s in "$TMATE_DIR"/*.sock; do
		_alive "$s" || continue
		[ "$(_name_of "$s")" = "$want" ] && {
			echo "$s"
			return 0
		}
	done
	return 1
}

cmd_new() {
	local name="${1:-}" s count=0
	for s in "$TMATE_DIR"/*.sock; do _alive "$s" && count=$((count + 1)); done
	[ "$count" -lt "$MAX_TMATE_SESSIONS" ] ||
		_die "session cap reached ($MAX_TMATE_SESSIONS); kill one first"

	local sock cwd
	sock=$(mktemp -u "$TMATE_DIR/XXXXXX.sock")
	[ -n "$name" ] || name=$(basename "$sock" .sock)
	_socket_for "$name" >/dev/null && _die "session '$name' already exists"

	cwd="${TMATE_CWD:-$PWD}"
	[ -d "$cwd" ] || cwd="$HOME"

	# env -u TMUX/TMATE so it can spawn from inside an existing tmate/tmux session.
	local err
	err=$(env -u TMUX -u TMATE tmate -S "$sock" new-session -d -s "$name" -c "$cwd" 2>&1) ||
		_die "failed to start tmate: ${err:-unknown}"
	if ! timeout "$READY_TIMEOUT" tmate -S "$sock" wait tmate-ready 2>/dev/null; then
		tmate -S "$sock" kill-server 2>/dev/null || true
		rm -f "$sock" 2>/dev/null || true
		_die "not ready within ${READY_TIMEOUT}s (relay unreachable?)"
	fi

	local ssh ssh_ro web web_ro
	ssh=$(tmate -S "$sock" display -p '#{tmate_ssh}' 2>/dev/null || true)
	ssh_ro=$(tmate -S "$sock" display -p '#{tmate_ssh_ro}' 2>/dev/null || true)
	web=$(tmate -S "$sock" display -p '#{tmate_web}' 2>/dev/null || true)
	web_ro=$(tmate -S "$sock" display -p '#{tmate_web_ro}' 2>/dev/null || true)

	echo "name:    $name"
	echo "socket:  $sock"
	echo "ssh:     $ssh"
	echo "ssh_ro:  $ssh_ro"
	echo "web:     $web"
	echo "web_ro:  $web_ro"

	_notify "$(printf 'New tmate session: %s\n```bash\n%s\n```\nweb: %s' \
		"$(_md2 "$name")" "$ssh" "$(_md2 "$web")")" || true
}

cmd_ls() {
	local s found=0
	for s in "$TMATE_DIR"/*.sock; do
		_alive "$s" || continue
		found=1
		printf '%s\t%s\t%s\n' "$(_name_of "$s")" "$s" \
			"$(tmate -S "$s" display -p '#{tmate_ssh}' 2>/dev/null || true)"
	done
	[ "$found" -eq 1 ] || echo "no active tmate sessions"
}

cmd_kill() {
	local name="${1:-}" sock
	[ -n "$name" ] || _die "usage: tmate-kill <name>"
	sock=$(_socket_for "$name") || _die "no session named '$name'"
	tmate -S "$sock" kill-server 2>/dev/null || true
	rm -f "$sock" 2>/dev/null || true
	echo "killed: $name"
}
cmd_boot() {
	local BOOT_SOCK="$TMATE_DIR/boot.sock" cwd
	# Idempotent: if the boot session is already alive, just report it.
	if _alive "$BOOT_SOCK"; then
		local ssh ssh_ro web web_ro
		ssh=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_ssh}' 2>/dev/null || true)
		ssh_ro=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_ssh_ro}' 2>/dev/null || true)
		web=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_web}' 2>/dev/null || true)
		web_ro=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_web_ro}' 2>/dev/null || true)
		echo "name:    boot"
		echo "socket:  $BOOT_SOCK"
		echo "ssh:     $ssh"
		echo "ssh_ro:  $ssh_ro"
		echo "web:     $web"
		echo "web_ro:  $web_ro"
		_notify "$(printf 'New tmate session: %s\n```bash\n%s\n```\nweb: %s' \
			"$(_md2 "boot")" "$ssh" "$(_md2 "$web")")" || true
		return 0
	fi
	# Clean stale socket.
	rm -f "$BOOT_SOCK" 2>/dev/null || true

	cwd="${TMATE_CWD:-$PWD}"
	[ -d "$cwd" ] || cwd="$HOME"

	local err
	err=$(env -u TMUX -u TMATE tmate -S "$BOOT_SOCK" new-session -d -s boot -c "$cwd" 2>&1) ||
		_die "failed to start tmate boot: ${err:-unknown}"
	if ! timeout "$READY_TIMEOUT" tmate -S "$BOOT_SOCK" wait tmate-ready 2>/dev/null; then
		tmate -S "$BOOT_SOCK" kill-server 2>/dev/null || true
		rm -f "$BOOT_SOCK" 2>/dev/null || true
		_die "boot not ready within ${READY_TIMEOUT}s (relay unreachable?)"
	fi

	# Size to the largest client so the idle control-mode monitor proxy
	# (cmd_wait's `-C attach-session`, 80x24) can't clamp the real SSH window.
	tmate -S "$BOOT_SOCK" set -g window-size largest 2>/dev/null || true

	local ssh ssh_ro web web_ro
	ssh=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_ssh}' 2>/dev/null || true)
	ssh_ro=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_ssh_ro}' 2>/dev/null || true)
	web=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_web}' 2>/dev/null || true)
	web_ro=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_web_ro}' 2>/dev/null || true)

	echo "name:    boot"
	echo "socket:  $BOOT_SOCK"
	echo "ssh:     $ssh"
	echo "ssh_ro:  $ssh_ro"
	echo "web:     $web"
	echo "web_ro:  $web_ro"

	_notify "$(printf 'New tmate session: %s\n```bash\n%s\n```\nweb: %s' \
		"$(_md2 "boot")" "$ssh" "$(_md2 "$web")")" || true
}

cmd_boot_socket() {
	local BOOT_SOCK="$TMATE_DIR/boot.sock"
	if _alive "$BOOT_SOCK"; then
		echo "$BOOT_SOCK"
		return 0
	fi
	return 1
}

cmd_wait() {
	local BOOT_SOCK="$TMATE_DIR/boot.sock"
	# Poll-only: never attach as a client. A control-mode (`-C attach`) proxy
	# counts as an 80x24 client and clamps the real SSH window to its size, so
	# we watch the socket instead of holding it. Death detected within one
	# TMATE_POLL_INTERVAL — fine for tmate (not latency-critical).
	while _alive "$BOOT_SOCK"; do
		sleep "${TMATE_POLL_INTERVAL:-5}"
	done
}
cmd_supervise() {
	local BOOT_SOCK="$TMATE_DIR/boot.sock"
	local LAST_SSH_FILE="$TMATE_DIR/last_ssh"
	local poll="${TMATE_POLL_INTERVAL:-2}" fails=0 delay
	local last_known="" prev_seen=""

	# Restore persisted last-known SSH string to survive tmate-tools process restarts.
	last_known=$(cat "$LAST_SSH_FILE" 2>/dev/null || true)
	[ -n "$last_known" ] && _log "supervise: restored last_known from $LAST_SSH_FILE"

	while true; do
		if _alive "$BOOT_SOCK"; then
			fails=0
			# Detect relay rotation: compare live SSH string against last notified.
			local current web
			current=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_ssh}' 2>/dev/null || true)

			if [ -n "$current" ] && [ "$current" != "$last_known" ]; then
				# Stability gate: require 2 consecutive identical readings before acting
				# to filter transient values during relay handshake.
				if [ "$current" = "$prev_seen" ]; then
					_log "supervise: SSH details changed — notifying"
					web=$(tmate -S "$BOOT_SOCK" display -p '#{tmate_web}' 2>/dev/null || true)
					if _notify "$(printf 'New tmate session: %s\n```bash\n%s\n```\nweb: %s' \
						"$(_md2 "boot")" "$current" "$(_md2 "$web")")"; then
						last_known="$current"
						printf '%s' "$current" > "$LAST_SSH_FILE" || true
						_log "supervise: notification delivered — last_known updated"
					else
						_log "supervise: notification failed — will retry next poll"
					fi
					prev_seen=""
				else
					_log "supervise: SSH candidate detected — awaiting stability confirmation"
					prev_seen="$current"
				fi
			else
				prev_seen=""
			fi

			sleep "$poll"
			continue
		fi

		# Boot session dead — restart. Suppress internal notify; this loop owns all notifications.
		_log "supervise: boot session lost — restarting"
		if ( TMATE_BOOT_NO_NOTIFY=1 cmd_boot ); then
			fails=0
			prev_seen=""  # let stability gate confirm new SSH before notifying
			_log "supervise: boot session restarted — awaiting SSH confirmation"
			sleep "$poll"
		else
			# relay unreachable — exponential backoff, capped.
			fails=$((fails + 1))
			delay=$((fails * 2))
			[ "$delay" -gt "${TMATE_BACKOFF_MAX:-30}" ] && delay="${TMATE_BACKOFF_MAX:-30}"
			_log "supervise: restart failed (attempt $fails) — backing off ${delay}s"
			sleep "$delay"
		fi
	done
}

action=""
case "${0##*/}" in
tmate-new) action="new" ;;
tmate-ls) action="ls" ;;
tmate-kill) action="kill" ;;
*)
	action="${1:-ls}"
	[ $# -gt 0 ] && shift || true
	;;
esac

case "$action" in
new) cmd_new "$@" ;;
ls | list) cmd_ls ;;
kill | rm) cmd_kill "$@" ;;
boot) cmd_boot ;;
boot-socket) cmd_boot_socket ;;
wait) cmd_wait ;;
supervise) cmd_supervise ;;
-h | --help | help) echo "usage: tmate-new [name] | tmate-ls | tmate-kill <name> | tmate-boot | tmate-boot-socket | tmate-wait | tmate-supervise" ;;
*) _die "unknown command '$action' (try --help)" ;;
esac
