"""gateway:startup hook — liveness ping + context-aware greeting.

Step A: deterministic Telegram ping (no LLM, survives model outages).
Step B: background AIAgent with SOUL + memory + session context.
"""

import json
import logging
import os
import sqlite3
import threading
import urllib.request
from datetime import datetime, timedelta, timezone

log = logging.getLogger("hooks.hermes-online")


def _local_now(tz_name: str) -> datetime:
    """Resolve current local time for tz_name without requiring system tzdata.

    Tries zoneinfo first (full DST support when tzdata is present), then falls
    back to a fixed-offset table for common DST-free zones, then to a literal
    UTC±HH:MM / ±HHMM string. Returns UTC if nothing resolves.
    """
    now_utc = datetime.now(timezone.utc)
    if not tz_name:
        return now_utc
    try:
        from zoneinfo import ZoneInfo

        return now_utc.astimezone(ZoneInfo(tz_name))
    except Exception as exc:
        log.warning("zoneinfo %r unavailable (%s); trying fixed offset", tz_name, exc)

    # DST-free zones whose offset never changes — safe as a constant.
    fixed = {
        "asia/kolkata": (5, 30), "asia/calcutta": (5, 30),
        "ist": (5, 30), "utc": (0, 0), "gmt": (0, 0),
    }
    key = tz_name.strip().lower()
    if key in fixed:
        h, m = fixed[key]
        return now_utc.astimezone(timezone(timedelta(hours=h, minutes=m)))

    # Literal offset like "UTC+5:30", "+05:30", "+0530".
    s = key.replace("utc", "").replace("gmt", "").strip()
    if s and s[0] in "+-":
        sign = 1 if s[0] == "+" else -1
        body = s[1:]
        try:
            if ":" in body:
                hh, mm = body.split(":", 1)
                h, m = int(hh), int(mm)
            else:
                h = int(body[:2]); m = int(body[2:4]) if len(body) > 2 else 0
            return now_utc.astimezone(timezone(sign * timedelta(hours=h, minutes=m)))
        except Exception:
            pass

    log.warning("boot tz %r unresolved; using UTC", tz_name)
    return now_utc

_HERMES_HOME = os.environ.get("HERMES_HOME", "/opt/data")
_SESSIONS_FILE = os.path.join(_HERMES_HOME, "sessions", "sessions.json")
_STATE_DB = os.path.join(_HERMES_HOME, "state.db")

# Boot-scoped once-guard. /tmp is ephemeral container storage — wiped on a real
# container boot, but survives in-place gateway service restarts inside the
# supervisor loop. So the online greeting fires exactly once per container boot,
# however many times gateway:startup is emitted (reconnects, restarts).
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
        # If the sentinel can't be created, fail open (greet) rather than go silent.
        log.warning("boot once-guard unavailable (%s); proceeding", exc)
        return True

# state.db schema is owned upstream and unversioned here; the timestamp column
# name varies across versions, so resolve it from a whitelist at query time.
_TS_COL_CANDIDATES = ("created_at", "timestamp", "ts", "time", "created")
_CONTENT_COL_CANDIDATES = ("content", "text", "message", "body", "data")


def _recent_topic(limit: int = 4, max_len: int = 160) -> str:
    """Best-effort gist of the most recent messages, for a warmer greeting that
    can reference what we were last on. Empty on any issue so the greeting cleanly
    falls back to the session-count context. Recipient is the user's own chat."""
    if not os.path.exists(_STATE_DB):
        return ""
    try:
        conn = sqlite3.connect(_STATE_DB, timeout=5)
        try:
            cols = {row[1] for row in conn.execute("PRAGMA table_info(messages)")}
            ts_col = next((c for c in _TS_COL_CANDIDATES if c in cols), None)
            content_col = next((c for c in _CONTENT_COL_CANDIDATES if c in cols), None)
            if ts_col is None or content_col is None:
                return ""
            # cols are from fixed whitelists, never user input → safe to inline.
            role_filter = "WHERE role IN ('user', 'assistant') " if "role" in cols else ""
            rows = conn.execute(
                f"SELECT {content_col} FROM messages {role_filter}"
                f"ORDER BY {ts_col} DESC LIMIT ?",
                (limit,),
            ).fetchall()
        finally:
            conn.close()
    except Exception:
        return ""
    snippets = []
    for (val,) in reversed(rows):
        text = " ".join(str(val or "").split())
        if not text:
            continue
        if len(text) > max_len:
            text = text[:max_len] + "…"
        snippets.append(text)
    if not snippets:
        return ""
    return "Recent thread (for context — reference the gist, don't quote verbatim):\n" + "\n".join(
        f"- {s}" for s in snippets
    )


def _agent_display_name() -> str:
    """Friendly agent name. AGENT_NAME defaults to the state-isolation key
    'primary' (start.sh), which is not a display name — fall back to Hermes."""
    explicit = os.environ.get("HERMES_AGENT_DISPLAY_NAME", "").strip()
    if explicit:
        return explicit
    name = os.environ.get("AGENT_NAME", "").strip()
    return name if name and name != "primary" else "Hermes"


def _send_telegram(text: str, chat_id: str) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not token or not chat_id:
        return
    base = os.environ.get("TELEGRAM_BASE_URL", "https://api.telegram.org/bot")
    payload = json.dumps({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(
        f"{base}{token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        if not data.get("ok"):
            log.warning("sendMessage failed: %s", data.get("description"))
    except Exception as exc:
        log.warning("sendMessage error: %s", exc)


def _load_sessions() -> dict:
    try:
        with open(_SESSIONS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def _message_count(session_id: str, since: datetime) -> int:
    if not session_id or not os.path.exists(_STATE_DB):
        return 0
    try:
        conn = sqlite3.connect(_STATE_DB, timeout=5)
        try:
            cols = {row[1] for row in conn.execute("PRAGMA table_info(messages)")}
            ts_col = next((c for c in _TS_COL_CANDIDATES if c in cols), None)
            if "session_id" not in cols or ts_col is None:
                return 0
            # ts_col is from a fixed whitelist, never user input → safe to inline.
            row = conn.execute(
                f"SELECT COUNT(*) FROM messages WHERE session_id = ? AND {ts_col} >= ?",
                (session_id, since.isoformat()),
            ).fetchone()
            return row[0] if row else 0
        finally:
            conn.close()
    except Exception:
        return 0


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
        local = _local_now(tz_name)
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

        # Telegram is connected (in platforms) and configured — greet once per boot.
        if not _claim_boot_once():
            log.info("Online greeting already sent this boot; skipping")
            return

        agent_name = _agent_display_name()
        tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
        local = _local_now(tz_name)

        # Step A — deterministic liveness ping (no LLM dependency).
        greeting = "Good morning" if local.hour < 12 else ("Good afternoon" if local.hour < 18 else "Good evening")
        alive_msg = f"✅ {agent_name} online — {greeting} {local.strftime('%Y-%m-%d %H:%M')}"
        _send_telegram(alive_msg, home_chat_id)

        # Step B — context-aware LLM greeting on background thread.
        thread = threading.Thread(
            target=_send_llm_greeting,
            args=(home_chat_id, agent_name),
            daemon=True,
        )
        thread.start()

    except Exception as exc:
        log.warning("hermes-online hook error: %s", exc)
