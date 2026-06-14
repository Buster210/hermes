"""gateway:startup hook — liveness ping + context-aware greeting.

Step A: deterministic Telegram ping (no LLM, survives model outages).
Step B: background AIAgent with SOUL + memory + session context.
"""

import importlib.util as _ilu
import logging
import os
import threading
from datetime import datetime, timedelta, timezone

log = logging.getLogger("hooks.hermes-online")


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
del _ilu, _u, _load_utils

_BOOT_SENTINEL = os.path.join(
    "/tmp", f"hermes-online.greeted.{os.environ.get('AGENT_NAME', 'primary')}"
)


def _claim_boot_once() -> bool:
    """Atomically claim the once-per-boot greeting. True for the first caller
    only; subsequent calls this boot return False. Race-safe across threads and
    processes via O_CREAT|O_EXCL."""
    try:
        fd = os.open(_BOOT_SENTINEL, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        return True
    except FileExistsError:
        return False
    except Exception as exc:
        log.warning("boot once-guard unavailable (%s); proceeding", exc)
        return True


def _build_context_summary() -> str:
    """Compact last-2-days session summary for the LLM prompt."""
    sessions = _load_sessions()
    if not sessions:
        return "No recent sessions found."

    now = datetime.now(timezone.utc)
    window = now - timedelta(days=2)
    tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
    try:
        from zoneinfo import ZoneInfo
        display_tz = ZoneInfo(tz_name)
    except Exception:
        display_tz = timezone(timedelta(hours=5, minutes=30))
    recent = []
    for key, s in sessions.items():
        updated = s.get("updated_at", "")
        if not updated:
            continue
        try:
            dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
        except Exception:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        if dt < window:
            continue

        sid = s.get("session_id", "")
        count = _message_count(sid, window) if sid else 0
        name = s.get("display_name") or s.get("origin", {}).get("user_name") or "unknown"
        platform = s.get("platform", "?")
        date_str = dt.astimezone(display_tz).strftime("%Y-%m-%d %H:%M IST")
        entry = f"- {name} ({platform}, {date_str})"
        if count:
            entry += f", {count} msgs"
        recent.append(entry)

    if not recent:
        return "No recent sessions in the last 2 days."
    return "Recent sessions (last 2 days):\n" + "\n".join(recent[-20:])


def _send_llm_greeting(home_chat_id: str, agent_name: str) -> None:
    """Background thread: build AIAgent, send in-character greeting."""
    try:
        from gateway.run import _resolve_gateway_model, _resolve_runtime_agent_kwargs
        from run_agent import AIAgent
    except ImportError as exc:
        log.warning("Cannot import agent modules (%s); skipping LLM greeting", exc)
        return

    try:
        summary = _build_context_summary()
        topic = _recent_topic()
        if topic:
            summary = f"{summary}\n\n{topic}"
        user_name = ""
        sessions = _load_sessions()
        for s in sessions.values():
            uname = s.get("origin", {}).get("user_name", "")
            if uname:
                user_name = uname
                break

        greet_target = user_name or "there"
        tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
        local = _local_now(tz_name, log=log)
        prompt = (
            f"You just came back online. Greet {greet_target} in your own voice as "
            f"{agent_name} — warm and personal, like picking up where you left off, not "
            f"a templated status ping. If the context below gives you something real to "
            f"reference (a topic you were on, their energy), weave it in naturally — "
            f"never force it.\n\n"
            f"The user is in India. The current local time is "
            f"{local.strftime('%A %Y-%m-%d %H:%M')} IST ({tz_name}). Always reason about "
            f"and express times in India Standard Time (IST, UTC+5:30) — never UTC or any "
            f"other timezone, unless the user explicitly asks otherwise.\n\n"
            f"Context:\n{summary}\n\n"
            f"Use the send_message tool to send ONE short greeting to "
            f"telegram chat {home_chat_id}. "
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
        log.warning("LLM greeting failed: %s", exc)


async def handle(event_type: str, context: dict) -> None:
    try:
        platforms = context.get("platforms", [])
        if "telegram" not in platforms:
            return

        home_chat_id = os.environ.get("TELEGRAM_HOME_CHANNEL", "")
        if not home_chat_id:
            log.info("No TELEGRAM_HOME_CHANNEL set; skipping online greeting")
            return

        if not _claim_boot_once():
            log.info("Online greeting already sent this boot; skipping")
            return

        agent_name = _agent_display_name()
        tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
        local = _local_now(tz_name, log=log)

        greeting = "Good morning" if local.hour < 12 else ("Good afternoon" if local.hour < 18 else "Good evening")
        alive_msg = f"✅ {agent_name} online — {greeting} {local.strftime('%Y-%m-%d %H:%M')}"
        _send_telegram(alive_msg, home_chat_id, log=log)

        thread = threading.Thread(
            target=_send_llm_greeting,
            args=(home_chat_id, agent_name),
            daemon=True,
        )
        thread.start()

    except Exception as exc:
        log.warning("hermes-online hook error: %s", exc)
