"""session:start hook — greet new sessions with same-day awareness.

Sends a full warm greeting on first session of the day,
brief "welcome back" on subsequent same-day sessions.
Throttle state kept in a per-user date-stamp file to avoid spam.
"""

import json
import logging
import os
import sqlite3
import threading
import urllib.request
from datetime import datetime, timedelta, timezone

log = logging.getLogger("hooks.session-greeting")


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

_HERMES_HOME = os.environ.get("HERMES_HOME", "/opt/data")
_SESSIONS_FILE = os.path.join(_HERMES_HOME, "sessions", "sessions.json")
_STATE_DB = os.path.join(_HERMES_HOME, "state.db")
_THROTTLE_DIR = os.path.join(_HERMES_HOME, "hooks", "session-greeting")
# Durable per-session_key markers: greet a given session exactly once, even if
# session:start re-fires for the same session. Survives restarts (lives under
# HERMES_HOME, not /tmp). Pruned to bound growth.
_GREETED_SESSIONS_DIR = os.path.join(_THROTTLE_DIR, "greeted-sessions")
_GREETED_TTL_SECONDS = 7 * 24 * 3600


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

# Re-entrancy guard: a greeting builds an AIAgent, whose own run could emit
# another session:start. While a user's greeting is in flight we drop further
# events for that user, so a self-triggered session can never loop. Doubles as
# anti-spam for rapid concurrent sessions.
_inflight_lock = threading.Lock()
_inflight_users: set = set()


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
            local = _local_now(tz_name)
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

        # Greet each session exactly once: drop repeat session:start for the same
        # session_key (the event can re-fire for one logical session).
        if not _claim_session_once(session_key):
            log.info("Session %s already greeted; skipping", session_key)
            return

        agent_name = _agent_display_name()
        now = datetime.now(timezone.utc)

        is_first = _is_first_session_today(user_id, now)

        # Policy: 'first-only' greets once per day; 'welcome-back' (default) also
        # sends a brief note on same-day re-entries.
        mode = os.environ.get("HERMES_SESSION_GREETING_MODE", "welcome-back").strip().lower()
        if mode == "first-only" and not is_first:
            return

        # Drop if a greeting is already in flight for this user (anti-recursion +
        # anti-spam). The spawned thread owns the release.
        with _inflight_lock:
            if user_id in _inflight_users:
                return
            _inflight_users.add(user_id)

        # Stamp only after committing to greet — marking on a guard-busy return
        # would suppress the day's real first-session greeting.
        _mark_greeted(user_id, now)

        spawned = False
        try:
            # Deterministic brief message for first session (no LLM dependency).
            if is_first:
                tz_name = os.environ.get("TELEGRAM_BOOT_TZ") or os.environ.get("TZ") or "Asia/Kolkata"
                local = _local_now(tz_name)
                greeting = "Good morning" if local.hour < 12 else ("Good afternoon" if local.hour < 18 else "Good evening")
                _send_telegram(f"✅ {greeting}, {display_name}! {agent_name} is here.", chat_id)

            # LLM greeting on background thread.
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
