"""session:start hook — greet new sessions with same-day awareness.

Sends a full warm greeting on first session of the day,
brief "welcome back" on subsequent same-day sessions.
Throttle state kept in a per-user date-stamp file to avoid spam.
"""

import importlib.util as _ilu
import logging
import os
import threading
from datetime import datetime, timedelta, timezone

log = logging.getLogger("hooks.session-greeting")


def _load_utils():
    import sys
    path = os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "_utils.py")
    )
    key = "_hermes_hook_utils"
    if key in sys.modules:
        return sys.modules[key]
    spec = _ilu.spec_from_file_location(key, path)
    mod = _ilu.module_from_spec(spec)
    sys.modules[key] = mod
    spec.loader.exec_module(mod)
    return mod


_u = _load_utils()
_local_now = _u._local_now
_agent_display_name = _u._agent_display_name
_send_telegram = _u._send_telegram
_load_sessions = _u._load_sessions
_recent_topic = _u._recent_topic
_message_count = _u._message_count
_HERMES_HOME = _u._HERMES_HOME
del _ilu, _u, _load_utils

_SESSIONS_FILE = os.path.join(_HERMES_HOME, "sessions", "sessions.json")
_STATE_DB = os.path.join(_HERMES_HOME, "state.db")
_THROTTLE_DIR = os.path.join(_HERMES_HOME, "hooks", "session-greeting")
_GREETED_SESSIONS_DIR = os.path.join(_THROTTLE_DIR, "greeted-sessions")
_GREETED_TTL_SECONDS = 7 * 24 * 3600

_inflight_lock = threading.Lock()
_inflight_users: set = set()


def _claim_session_once(session_key: str) -> bool:
    """Atomically claim the one greeting for this session_key. True for the first
    caller only; later session:start events for the same session return False.
    Race-safe via O_CREAT|O_EXCL. Fails open if the marker can't be written."""
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in session_key)[:200]
    marker = os.path.join(_GREETED_SESSIONS_DIR, safe)
    try:
        os.makedirs(_GREETED_SESSIONS_DIR, exist_ok=True)
        _prune_greeted_sessions()
        fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        return True
    except FileExistsError:
        return False
    except Exception as exc:
        log.warning("session once-guard unavailable (%s); proceeding", exc)
        return True


def _prune_greeted_sessions() -> None:
    """Drop session markers older than the TTL so the dir can't grow unbounded."""
    try:
        cutoff = datetime.now(timezone.utc).timestamp() - _GREETED_TTL_SECONDS
        for name in os.listdir(_GREETED_SESSIONS_DIR):
            path = os.path.join(_GREETED_SESSIONS_DIR, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    os.remove(path)
            except Exception:
                pass
    except Exception:
        pass


def _is_first_session_today(user_id: str, now: datetime) -> bool:
    """True if this user has had no other session today."""
    today = now.strftime("%Y-%m-%d")
    throttle_file = os.path.join(_THROTTLE_DIR, f".last-greet-{user_id}")
    try:
        with open(throttle_file, "r") as f:
            return f.read().strip() != today
    except FileNotFoundError:
        return True
    except Exception:
        return True


def _mark_greeted(user_id: str, now: datetime) -> None:
    today = now.strftime("%Y-%m-%d")
    throttle_file = os.path.join(_THROTTLE_DIR, f".last-greet-{user_id}")
    try:
        os.makedirs(_THROTTLE_DIR, exist_ok=True)
        with open(throttle_file, "w") as f:
            f.write(today)
    except Exception:
        pass


def _build_today_context(user_id: str, current_key: str, now: datetime) -> str:
    """Context summary for today's sessions (excludes current)."""
    sessions = _load_sessions()
    today_str = now.strftime("%Y-%m-%d")
    today_sessions = []
    for key, s in sessions.items():
        if key == current_key:
            continue
        origin = s.get("origin", {})
        if origin.get("user_id") != user_id:
            continue
        created = s.get("created_at", "")
        if not created:
            continue
        try:
            dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
            if dt.strftime("%Y-%m-%d") != today_str:
                continue
        except Exception:
            continue

        sid = s.get("session_id", "")
        count = _message_count(sid, now - timedelta(days=1)) if sid else 0
        time_str = dt.strftime("%H:%M")
        entry = f"- Session at {time_str}"
        if count:
            entry += f" ({count} msgs)"
        today_sessions.append(entry)

    if not today_sessions:
        return "This is the first session today."
    return "Today's earlier sessions:\n" + "\n".join(today_sessions)


def _send_llm_greeting(
    chat_id: str,
    display_name: str,
    is_first: bool,
    context_summary: str,
    agent_name: str,
    user_id: str,
) -> None:
    """Background thread: build AIAgent, send greeting. Always releases the
    in-flight guard for user_id, so a crash can't wedge greetings off."""
    try:
        try:
            from gateway.run import _resolve_gateway_model, _resolve_runtime_agent_kwargs
            from run_agent import AIAgent
        except ImportError as exc:
            log.warning("Cannot import agent modules (%s); skipping greeting", exc)
            return

        try:
            shape = (
                "a full but natural greeting" if is_first
                else "a short, casual welcome-back (same-day re-entry)"
            )
            tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
            local = _local_now(tz_name, log=log)
            prompt = (
                f"A new session just started for {display_name}. Greet them in your own "
                f"voice — warm and personal, like a friend picking up where you left off, "
                f"not a templated bot. Keep it {shape}. If the context below gives you "
                f"something real to reference (a topic you were on, their energy), weave "
                f"it in naturally — never force it.\n\n"
                f"The user is in India. The current local time is "
                f"{local.strftime('%A %Y-%m-%d %H:%M')} IST ({tz_name}). Always reason about "
                f"and express times in India Standard Time (IST, UTC+5:30) — never UTC or any "
                f"other timezone, unless the user explicitly asks otherwise.\n\n"
                f"{context_summary}\n\n"
                f"Use the send_message tool to send ONE short greeting to "
                f"telegram chat {chat_id}. "
                f"If nothing meaningful to say, reply [SILENT]."
            )

            agent = AIAgent(
                model=_resolve_gateway_model(),
                **_resolve_runtime_agent_kwargs(),
                platform="gateway",
                quiet_mode=True,
                skip_context_files=True,
            )
            agent.run(prompt)
        except Exception as exc:
            log.warning("Session greeting LLM failed: %s", exc)
    finally:
        with _inflight_lock:
            _inflight_users.discard(user_id)


async def handle(event_type: str, context: dict) -> None:
    try:
        platform = context.get("platform", "")
        if platform != "telegram":
            return

        user_id = context.get("user_id", "")
        session_key = context.get("session_key", "")
        if not user_id or not session_key:
            log.info("Missing user_id or session_key; skipping greeting")
            return

        sessions = _load_sessions()
        session = sessions.get(session_key)
        if not session:
            log.info("Session %s not found in registry; skipping greeting", session_key)
            return

        chat_id = session.get("origin", {}).get("chat_id", "")
        display_name = session.get("display_name") or session.get("origin", {}).get("user_name", "there")
        if not chat_id:
            log.info("No chat_id for session %s; skipping greeting", session_key)
            return

        if not _claim_session_once(session_key):
            log.info("Session %s already greeted; skipping", session_key)
            return

        agent_name = _agent_display_name()
        now = datetime.now(timezone.utc)

        is_first = _is_first_session_today(user_id, now)

        mode = os.environ.get("HERMES_SESSION_GREETING_MODE", "welcome-back").strip().lower()
        if mode == "first-only" and not is_first:
            return

        with _inflight_lock:
            if user_id in _inflight_users:
                return
            _inflight_users.add(user_id)

        _mark_greeted(user_id, now)

        spawned = False
        try:
            if is_first:
                tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
                local = _local_now(tz_name, log=log)
                greeting = "Good morning" if local.hour < 12 else ("Good afternoon" if local.hour < 18 else "Good evening")
                _send_telegram(f"✅ {greeting}, {display_name}! {agent_name} is here.", chat_id, log=log)

            context_summary = _build_today_context(user_id, session_key, now)
            topic = _recent_topic()
            if topic:
                context_summary = f"{context_summary}\n\n{topic}"
            thread = threading.Thread(
                target=_send_llm_greeting,
                args=(chat_id, display_name, is_first, context_summary, agent_name, user_id),
                daemon=True,
            )
            thread.start()
            spawned = True
        finally:
            if not spawned:
                with _inflight_lock:
                    _inflight_users.discard(user_id)

    except Exception as exc:
        log.warning("session-greeting hook error: %s", exc)
