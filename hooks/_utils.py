"""Shared utilities for hermes hooks (loaded at runtime via importlib).

Load via spec_from_file_location so hyphenated hook directory names (which are
invalid Python identifiers) don't block the import. Cached in sys.modules under
'_hermes_hook_utils' so both hooks share one module instance per process.
"""

import json
import os
import sqlite3
import urllib.request
from datetime import datetime, timedelta, timezone

_HERMES_HOME = os.environ.get("HERMES_HOME", "/opt/data")
_SESSIONS_FILE = os.path.join(_HERMES_HOME, "sessions", "sessions.json")
_STATE_DB = os.path.join(_HERMES_HOME, "state.db")

_TS_COL_CANDIDATES = ("created_at", "timestamp", "ts", "time", "created")
_CONTENT_COL_CANDIDATES = ("content", "text", "message", "body", "data")


def _local_now(tz_name: str, *, log) -> datetime:
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

    fixed = {
        "asia/kolkata": (5, 30), "asia/calcutta": (5, 30),
        "ist": (5, 30), "utc": (0, 0), "gmt": (0, 0),
    }
    key = tz_name.strip().lower()
    if key in fixed:
        h, m = fixed[key]
        return now_utc.astimezone(timezone(timedelta(hours=h, minutes=m)))

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


def _agent_display_name() -> str:
    """Friendly agent name. AGENT_NAME defaults to the state-isolation key
    'primary' (start.sh), which is not a display name — fall back to Hermes."""
    explicit = os.environ.get("HERMES_AGENT_DISPLAY_NAME", "").strip()
    if explicit:
        return explicit
    name = os.environ.get("AGENT_NAME", "").strip()
    return name if name and name != "primary" else "Hermes"


def _send_telegram(text: str, chat_id: str, *, log) -> None:
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
            row = conn.execute(
                f"SELECT COUNT(*) FROM messages WHERE session_id = ? AND {ts_col} >= ?",
                (session_id, since.isoformat()),
            ).fetchone()
            return row[0] if row else 0
        finally:
            conn.close()
    except Exception:
        return 0
