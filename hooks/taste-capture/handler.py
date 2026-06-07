"""session:end hook — capture taste signals (corrections / redos / rejections).

Deterministic and LLM-free: scans recent messages for signs that Ritesh
corrected, redid, or rejected an output, and appends the exchange to a taste
signal queue (memories/longterm/TASTE-signals.md). The taste-capture skill
(cron) later distills the queue into a confidence-gated preferences profile.

Self-contained: no cross-hook imports. Fails open and quiet — a capture hook
must never block the agent pipeline. Secrets are redacted before any disk write.
"""

import hashlib
import logging
import os
import re
import sqlite3
from datetime import datetime, timezone

log = logging.getLogger("hooks.taste-capture")

_HERMES_HOME = os.environ.get("HERMES_HOME", "/opt/data")
_STATE_DB = os.path.join(_HERMES_HOME, "state.db")
_LONGTERM_DIR = os.path.join(_HERMES_HOME, "memories", "longterm")
_SIGNALS_FILE = os.path.join(_LONGTERM_DIR, "TASTE-signals.md")
_SEEN_FILE = os.path.join(_HERMES_HOME, "hooks", "taste-capture", ".seen-signals")

_SCAN_LIMIT = 60            # recent messages to inspect per session end
_SEEN_CAP = 300             # remembered signal hashes to avoid re-capture
_SIGNALS_MAX_BYTES = 32768  # cap the queue so it can never grow unbounded
_MSG_MAX_LEN = 240          # truncate each captured message

# state.db schema is owned upstream and unversioned here; resolve columns from a
# whitelist at query time (mirrors the session-greeting hook).
_TS_COL_CANDIDATES = ("created_at", "timestamp", "ts", "time", "created")
_CONTENT_COL_CANDIDATES = ("content", "text", "message", "body", "data")

# Correction / rejection / restyle markers. The whole alternation is wrapped in
# word boundaries so short markers ("no", "not") can't fire inside other words.
_MARKERS = (
    r"no", r"nope", r"don'?t", r"do not", r"not", r"wrong", r"incorrect",
    r"actually", r"instead", r"rather", r"revert", r"undo", r"redo", r"again",
    r"too long", r"too verbose", r"too short", r"shorter", r"terser",
    r"concise", r"less", r"simpler", r"fluff", r"that'?s not",
    r"did ?n'?t work", r"does ?n'?t work", r"not what i", r"you forgot",
    r"missed", r"stop", r"fix this", r"that'?s wrong",
)
_MARKER_RE = re.compile(r"(?i)\b(?:" + "|".join(_MARKERS) + r")\b")

# Conservative secret/PII redaction applied before anything touches disk. Bias
# toward over-redaction — a false positive in a taste file is harmless; a leaked
# secret is not. The token rule needs ≥20 chars with both a digit and a letter,
# so it catches keys/IDs (AWS, bearer, hex) but not plain long words.
_SECRET_RES = (
    re.compile(r"(?i)\b(?:sk|pk|rk|api|key|token|bearer|secret|pass(?:word)?)[-_]?[=:]\s*\S+"),
    re.compile(r"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"),
)


def _redact(text: str) -> str:
    out = text or ""
    for rx in _SECRET_RES:
        out = rx.sub("[redacted]", out)
    return out


def _clean(text: str) -> str:
    t = " ".join((text or "").split())
    return (t[:_MSG_MAX_LEN] + "…") if len(t) > _MSG_MAX_LEN else t


def _load_seen() -> set:
    try:
        with open(_SEEN_FILE, "r") as f:
            return {ln.strip() for ln in f if ln.strip()}
    except Exception:
        return set()


def _save_seen(hashes: list) -> None:
    try:
        os.makedirs(os.path.dirname(_SEEN_FILE), exist_ok=True)
        with open(_SEEN_FILE, "w") as f:
            f.write("\n".join(hashes[-_SEEN_CAP:]) + "\n")
    except Exception:
        pass


def _recent_messages() -> list:
    """Recent (role, content) in chronological order, or [] on any issue."""
    if not os.path.exists(_STATE_DB):
        return []
    try:
        conn = sqlite3.connect(_STATE_DB, timeout=5)
        try:
            cols = {row[1] for row in conn.execute("PRAGMA table_info(messages)")}
            ts_col = next((c for c in _TS_COL_CANDIDATES if c in cols), None)
            content_col = next((c for c in _CONTENT_COL_CANDIDATES if c in cols), None)
            if ts_col is None or content_col is None or "role" not in cols:
                return []
            # cols come from fixed whitelists, never user input → safe to inline.
            rows = conn.execute(
                f"SELECT role, {content_col} FROM messages "
                f"WHERE role IN ('user','assistant') AND {content_col} IS NOT NULL "
                f"ORDER BY {ts_col} DESC LIMIT ?",
                (_SCAN_LIMIT,),
            ).fetchall()
        finally:
            conn.close()
    except Exception:
        return []
    return [(str(r[0] or ""), str(r[1] or "")) for r in reversed(rows)]


def _append_signals(blocks: list) -> None:
    try:
        os.makedirs(_LONGTERM_DIR, exist_ok=True)
        existing = ""
        if os.path.exists(_SIGNALS_FILE):
            with open(_SIGNALS_FILE, "r") as f:
                existing = f.read()
        if not existing:
            existing = (
                "# TASTE signals — raw correction/redo/rejection candidates\n"
                "# Queue for the taste-capture skill; cleared after consolidation.\n\n"
            )
        combined = existing + "\n".join(blocks) + "\n"
        # Bound the queue: if oversized, keep the newest tail.
        encoded = combined.encode("utf-8")
        if len(encoded) > _SIGNALS_MAX_BYTES:
            combined = encoded[-_SIGNALS_MAX_BYTES:].decode("utf-8", "ignore")
        with open(_SIGNALS_FILE, "w") as f:
            f.write(combined)
    except Exception as exc:
        log.warning("taste-capture append failed: %s", exc)


async def handle(event_type: str, context: dict) -> None:
    try:
        msgs = _recent_messages()
        if not msgs:
            return
        seen = _load_seen()
        new_blocks, new_hashes = [], []
        last_agent = ""
        for role, content in msgs:
            if role == "assistant":
                last_agent = content
                continue
            if role != "user" or not content or not _MARKER_RE.search(content):
                continue
            user_red = _clean(_redact(content))
            agent_red = _clean(_redact(last_agent)) if last_agent else ""
            digest = hashlib.sha1(
                (agent_red + "\x1f" + user_red).encode("utf-8", "ignore")
            ).hexdigest()[:16]
            if digest in seen or digest in new_hashes:
                continue
            stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            new_blocks.append(
                f"### {stamp}\n~ agent: {agent_red or '(none)'}\n~ user: {user_red}\n"
            )
            new_hashes.append(digest)
        if not new_blocks:
            return
        _append_signals(new_blocks)
        _save_seen(list(seen) + new_hashes)
    except Exception as exc:
        log.warning("taste-capture hook error: %s", exc)
