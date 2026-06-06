#!/usr/bin/env python3
"""Hermes state backup via HF Storage Buckets. Vendored from HuggingMes.

Backs up $HERMES_HOME (sessions, profiles, skills, cron, memory, workspace,
plugins, webui state) so the full agent workspace survives Space restarts.

Each agent writes under its own prefix (AGENT_NAME) inside one shared private
bucket, so many agents share a bucket without clobbering each other."""

import hashlib
import json
import logging
import os
import shutil
import signal
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_VERBOSITY", "error")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
# hf_transfer → HF_XET_HIGH_PERFORMANCE avoids FutureWarning on hub >=0.30
os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")

from huggingface_hub import HfApi, snapshot_download
from huggingface_hub.errors import HfHubHTTPError, RepositoryNotFoundError

logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/opt/data"))
STATUS_FILE = Path("/tmp/hermes-sync-status.json")
STATE_FILE = HERMES_HOME / ".hermes-sync-state.json"
INTERVAL = int(os.environ.get("SYNC_INTERVAL", "60"))
INITIAL_DELAY = int(os.environ.get("SYNC_START_DELAY", "5"))
# Change-driven: poll metadata, wait DEBOUNCE quiet, cap at INTERVAL ceiling.
POLL_INTERVAL = float(os.environ.get("SYNC_POLL_INTERVAL", "2"))
DEBOUNCE_SECONDS = float(os.environ.get("SYNC_DEBOUNCE_SECONDS", "3"))
HF_TOKEN = os.environ.get("HF_TOKEN", "").strip()
HF_USERNAME = os.environ.get("HF_USERNAME", "").strip()
SPACE_AUTHOR_NAME = os.environ.get("SPACE_AUTHOR_NAME", "").strip()
# Bucket holding every agent's backup; each agent lives under its own prefix.
BACKUP_BUCKET_NAME = os.environ.get("BACKUP_BUCKET_NAME", "hermes-backup").strip()
# Per-agent prefix inside the shared bucket. Lowercased so casing can't split a prefix.
AGENT_NAME = (os.environ.get("AGENT_NAME", "").strip() or "primary").lower()
# One-time legacy dataset → bucket migration when an agent's prefix is still empty.
BACKUP_DATASET_NAME = os.environ.get("BACKUP_DATASET_NAME", "hermes-backup").strip()
MIGRATE_FROM_DATASET = os.environ.get("MIGRATE_FROM_DATASET", "true").strip().lower() in {"1", "true", "yes"}
INCLUDE_ENV = os.environ.get("SYNC_INCLUDE_ENV", "").strip().lower() in {"1", "true", "yes"}
MAX_FILE_SIZE_BYTES = int(os.environ.get("SYNC_MAX_FILE_BYTES", str(50 * 1024 * 1024)))

EXCLUDED_DIRS = {
    ".cache",
    ".git",
    ".npm",
    ".venv",
    "__pycache__",
    "node_modules",
    "venv",
    "logs",          # log files are useless after a restart
}
EXCLUDED_TOP_LEVEL = {"logs", STATE_FILE.name}
EXCLUDED_SUFFIXES = (
    ".log", ".log.1", ".log.2",
    ".db-shm", ".db-wal", ".db-journal",
    ".pid", ".tmp",
)
if not INCLUDE_ENV:
    EXCLUDED_TOP_LEVEL.add(".env")

HF_API = HfApi(token=HF_TOKEN) if HF_TOKEN else None
STOP_EVENT = threading.Event()
_NAMESPACE_CACHE: str | None = None

# .env warning: dashboard writes keys here, wiped on restart. Not backed up
# by default (secrets in a backup is the wrong tradeoff). Status page banner.
ENV_FILE = HERMES_HOME / ".env"
ON_HF_SPACE = bool(os.environ.get("SPACE_ID") or os.environ.get("SPACE_HOST"))


def env_warning_payload() -> dict | None:
    """Detect plaintext-secret-loss risk on HF Spaces with .env and SYNC_INCLUDE_ENV off."""
    if not ON_HF_SPACE or INCLUDE_ENV:
        return None
    try:
        if not ENV_FILE.is_file():
            return None
        # Count non-empty, non-comment lines as a proxy for "user-set keys".
        keys = 0
        for raw in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                keys += 1
        if keys <= 0:
            return None
        return {
            "kind": "ephemeral_env",
            "keys": keys,
            "message": (
                f"{keys} entr{'y' if keys == 1 else 'ies'} in $HERMES_HOME/.env "
                "will be wiped on the next Space restart. Move secrets to "
                "Space Secrets (Settings -> Variables and secrets), or set "
                "SYNC_INCLUDE_ENV=1 to back up .env to the private bucket "
                "(plaintext; weaker security)."
            ),
        }
    except OSError:
        return None


def write_status(status: str, message: str, fingerprint: str | None = None, marker: tuple[int, int, int] | None = None) -> None:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    payload: dict = {"status": status, "message": message, "timestamp": timestamp}
    warning = env_warning_payload()
    if warning is not None:
        payload["warning"] = warning

    tmp_path = STATUS_FILE.with_suffix(".tmp")
    try:
        tmp_path.write_text(json.dumps(payload), encoding="utf-8")
        tmp_path.replace(STATUS_FILE)
    except OSError:
        pass

    if fingerprint or marker:
        state = {}
        if STATE_FILE.exists():
            try:
                state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            except Exception:
                pass
        if fingerprint:
            state["last_fingerprint"] = fingerprint
        if marker:
            state["last_marker"] = list(marker)
        state["last_sync"] = timestamp
        try:
            STATE_FILE.write_text(json.dumps(state), encoding="utf-8")
        except OSError:
            pass


def resolve_namespace() -> str:
    global _NAMESPACE_CACHE
    if _NAMESPACE_CACHE:
        return _NAMESPACE_CACHE

    namespace = HF_USERNAME or SPACE_AUTHOR_NAME
    if not namespace and HF_API is not None:
        whoami = HF_API.whoami()
        namespace = whoami.get("name") or whoami.get("user") or ""

    namespace = str(namespace).strip()
    if not namespace:
        raise RuntimeError("Could not determine HF username. Set HF_USERNAME or use an account HF_TOKEN.")

    _NAMESPACE_CACHE = namespace
    return namespace


def resolve_backup_bucket() -> str:
    """Bucket id (``namespace/BACKUP_BUCKET_NAME``) shared by every agent."""
    return f"{resolve_namespace()}/{BACKUP_BUCKET_NAME}"


def remote_uri() -> str:
    """This agent's prefix inside the shared bucket."""
    return f"hf://buckets/{resolve_backup_bucket()}/{AGENT_NAME}"


def ensure_bucket_exists() -> str:
    bucket_id = resolve_backup_bucket()
    # exist_ok makes this a create-only-if-missing no-op when the bucket is already there.
    HF_API.create_bucket(bucket_id, private=True, exist_ok=True)
    return bucket_id


def _is_404(exc: HfHubHTTPError) -> bool:
    return exc.response is not None and exc.response.status_code == 404


def bucket_prefix_empty(bucket_id: str) -> bool:
    """True when this agent's prefix holds no files yet (or doesn't exist)."""
    try:
        for _ in HF_API.list_bucket_tree(bucket_id, prefix=AGENT_NAME):
            return False
    except (RepositoryNotFoundError, HfHubHTTPError):
        return True
    except Exception:
        return True
    return True


def should_exclude(rel_posix: str, path: Path) -> bool:
    parts = Path(rel_posix).parts
    if not parts:
        return False
    if parts[0] in EXCLUDED_TOP_LEVEL:
        return True
    if any(part in EXCLUDED_DIRS for part in parts):
        return True
    if path.is_file():
        name_lower = path.name.lower()
        if name_lower.endswith(EXCLUDED_SUFFIXES):
            return True
        try:
            return path.stat().st_size > MAX_FILE_SIZE_BYTES
        except OSError:
            return True
    return False


def metadata_marker(root: Path) -> tuple[int, int, int]:
    if not root.exists():
        return (0, 0, 0)
    file_count = 0
    total_size = 0
    newest_mtime = 0
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if should_exclude(rel, path):
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        file_count += 1
        total_size += int(stat.st_size)
        newest_mtime = max(newest_mtime, int(stat.st_mtime_ns))
    return (file_count, total_size, newest_mtime)


def fingerprint_dir(root: Path) -> str:
    hasher = hashlib.sha256()
    if not root.exists():
        return hasher.hexdigest()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        if should_exclude(rel, path):
            continue
        hasher.update(rel.encode("utf-8"))
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
    return hasher.hexdigest()


def create_snapshot_dir(source_root: Path) -> Path:
    staging_root = Path(tempfile.mkdtemp(prefix="hermes-sync-"))
    for path in sorted(source_root.rglob("*")):
        rel = path.relative_to(source_root)
        rel_posix = rel.as_posix()
        if should_exclude(rel_posix, path):
            continue
        target = staging_root / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(path, target)
        except OSError:
            continue
    return staging_root


def _push_snapshot(uri: str, delete: bool) -> None:
    """Upload an exclude-filtered snapshot of HERMES_HOME to the agent prefix.

    Routed through create_snapshot_dir so byte-identical exclude semantics
    (including the 50MB cap) hold for both routine syncs and migration seeds."""
    snapshot_dir = create_snapshot_dir(HERMES_HOME)
    try:
        HF_API.sync_bucket(str(snapshot_dir), uri, delete=delete, quiet=True)
    finally:
        shutil.rmtree(snapshot_dir, ignore_errors=True)


def _merge_into_home(source_root: Path) -> None:
    """Child-merge non-excluded top-level entries of source_root into HERMES_HOME."""
    HERMES_HOME.mkdir(parents=True, exist_ok=True)
    for child in source_root.iterdir():
        if should_exclude(child.name, child):
            continue
        target = HERMES_HOME / child.name
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        elif target.exists():
            target.unlink()
        if child.is_dir():
            shutil.copytree(child, target)
        else:
            shutil.copy2(child, target)


def migrate_from_dataset(uri: str) -> bool:
    """One-time legacy dataset → bucket move.

    Pulls the old private dataset, child-merges it into HERMES_HOME with the
    same exclude logic as restore, then seeds the agent's bucket prefix.
    Returns False (no migration) when the dataset is absent or empty."""
    dataset_repo = f"{resolve_namespace()}/{BACKUP_DATASET_NAME}"
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                snapshot_download(repo_id=dataset_repo, repo_type="dataset", token=HF_TOKEN, local_dir=tmpdir)
            except RepositoryNotFoundError:
                return False
            except HfHubHTTPError as exc:
                if _is_404(exc):
                    return False
                raise
            tmp_path = Path(tmpdir)
            if not any(tmp_path.iterdir()):
                return False
            _merge_into_home(tmp_path)
        # Seed the bucket prefix from the freshly-populated HERMES_HOME.
        _push_snapshot(uri, delete=False)
        return True
    except Exception as exc:
        print(f"Dataset migration failed: {exc}", file=sys.stderr)
        return False


def restore() -> bool:
    if not HF_TOKEN:
        write_status("disabled", "HF_TOKEN is not configured.")
        return False

    uri = remote_uri()
    write_status("restoring", f"Restoring Hermes state from {uri}")
    try:
        bucket_id = ensure_bucket_exists()
        HERMES_HOME.mkdir(parents=True, exist_ok=True)
        # Download the agent prefix into HERMES_HOME. No delete: baked-in local
        # files (config, plugins) must survive a restore of an empty/partial prefix.
        try:
            HF_API.sync_bucket(uri, str(target), quiet=True)
        except RepositoryNotFoundError:
            pass
        except HfHubHTTPError as exc:
            if not _is_404(exc):
                raise

        if not bucket_prefix_empty(bucket_id):
            write_status("restored", f"Restored Hermes state from {uri}")
            return True

        # Empty prefix: try the one-time dataset migration, else start fresh.
        if MIGRATE_FROM_DATASET and migrate_from_dataset(uri):
            write_status("migrated", f"Migrated legacy dataset backup into {uri}")
            return True

        write_status("fresh", f"Backup prefix {AGENT_NAME} is empty. Starting fresh.")
        return True
    except RepositoryNotFoundError:
        write_status("fresh", f"Backup bucket for {uri} does not exist yet.")
        return True
    except HfHubHTTPError as exc:
        if _is_404(exc):
            write_status("fresh", f"Backup bucket for {uri} does not exist yet.")
            return True
        write_status("error", f"Restore failed: {exc}")
        print(f"Restore failed: {exc}", file=sys.stderr)
        return False
    except Exception as exc:
        write_status("error", f"Restore failed: {exc}")
        print(f"Restore failed: {exc}", file=sys.stderr)
        return False


def migrate() -> bool:
    """Force the legacy dataset → bucket migration once, regardless of prefix state."""
    if not HF_TOKEN:
        write_status("disabled", "HF_TOKEN is not configured.")
        return False
    try:
        ensure_bucket_exists()
        uri = remote_uri()
        if migrate_from_dataset(uri):
            write_status("migrated", f"Migrated legacy dataset backup into {uri}")
            return True
        write_status("fresh", "No legacy dataset backup found to migrate.")
        return True
    except Exception as exc:
        write_status("error", f"Migration failed: {exc}")
        print(f"Migration failed: {exc}", file=sys.stderr)
        return False


def sync_once(last_fingerprint: str | None = None, last_marker: tuple[int, int, int] | None = None):
    if last_fingerprint is None and last_marker is None:
        if STATE_FILE.exists():
            try:
                state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
                last_fingerprint = state.get("last_fingerprint")
                m = state.get("last_marker")
                if m and len(m) == 3:
                    last_marker = tuple(m)
            except Exception:
                pass

    ensure_bucket_exists()
    uri = remote_uri()
    current_marker = metadata_marker(HERMES_HOME)
    if last_marker is not None and current_marker == last_marker:
        write_status("synced", "No Hermes state changes detected (marker match).")
        return (last_fingerprint or "", current_marker)

    current_fingerprint = fingerprint_dir(HERMES_HOME)
    if last_fingerprint is not None and current_fingerprint == last_fingerprint:
        write_status("synced", "No Hermes state changes detected (fingerprint match).")
        return (last_fingerprint, current_marker)

    hostname = socket.gethostname()
    write_status("syncing", f"Uploading Hermes state to {uri} from {hostname}")
    # delete=True so removals propagate to the agent prefix (excludes already filtered).
    _push_snapshot(uri, delete=True)

    write_status("success", f"Uploaded Hermes state to {uri}", fingerprint=current_fingerprint, marker=current_marker)
    return (current_fingerprint, current_marker)


def handle_signal(_sig, _frame) -> None:
    STOP_EVENT.set()


def loop() -> int:
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    try:
        uri = remote_uri()
        write_status(
            "configured",
            f"Backup watcher active for {uri} "
            f"(poll={POLL_INTERVAL}s, debounce={DEBOUNCE_SECONDS}s, max={INTERVAL}s).",
        )
    except Exception as exc:
        write_status("error", str(exc))
        print(f"Hermes sync error: {exc}")
        return 1

    warning = env_warning_payload()
    if warning is not None:
        # One-liner so it's greppable in HF logs.
        print(f"Hermes sync WARNING: {warning['message']}")

    # Seed from prior run to avoid re-uploading identical tree.
    last_fingerprint: str | None = None
    last_marker: tuple[int, int, int] | None = None
    if STATE_FILE.exists():
        try:
            state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            last_fingerprint = state.get("last_fingerprint")
            m = state.get("last_marker")
            if m and len(m) == 3:
                last_marker = tuple(m)
        except Exception:
            pass
    if last_marker is None:
        last_marker = metadata_marker(HERMES_HOME)

    if STOP_EVENT.wait(INITIAL_DELAY):
        return 0
    print(
        f"Hermes state sync started: poll={POLL_INTERVAL}s "
        f"debounce={DEBOUNCE_SECONDS}s max={INTERVAL}s -> {uri}"
    )

    # Change-driven scheduler. Two clocks:
    #   * `pending_since`     — when we first noticed an unsynced change. Used
    #                           with INTERVAL to enforce a hard ceiling so a
    #                           continuously-busy session can't starve uploads.
    #   * `last_change_at`    — when we most recently saw the marker move. The
    #                           debounce timer is measured against this so we
    #                           wait for writes to settle before uploading.
    pending_since: float | None = None
    last_change_at: float | None = None
    candidate_marker = last_marker

    while not STOP_EVENT.is_set():
        if STOP_EVENT.wait(POLL_INTERVAL):
            break

        try:
            current_marker = metadata_marker(HERMES_HOME)
        except Exception as exc:
            # Don't let a transient stat error kill the loop.
            write_status("error", f"marker scan failed: {exc}")
            continue

        now = time.time()

        if current_marker != candidate_marker:
            # Files moved since the last poll. Start (or extend) a debounce.
            if pending_since is None:
                pending_since = now
            last_change_at = now
            candidate_marker = current_marker
            continue

        if pending_since is None:
            # Tree is unchanged and there's nothing waiting. Nothing to do.
            continue

        quiet_for = now - (last_change_at or now)
        held_for = now - pending_since
        # Trigger when writes have settled (debounce) OR when the hard ceiling
        # is hit, so a never-idle tree still gets snapshotted at least once
        # per INTERVAL seconds.
        if quiet_for < DEBOUNCE_SECONDS and held_for < INTERVAL:
            continue

        try:
            last_fingerprint, last_marker = sync_once(last_fingerprint, last_marker)
            candidate_marker = last_marker
        except Exception as exc:
            write_status("error", f"Sync failed: {exc}")
            print(f"Hermes sync failed: {exc}")
            # Back off briefly on failure so we don't hot-loop a broken upload.
            if STOP_EVENT.wait(min(5.0, POLL_INTERVAL * 2)):
                break
        finally:
            pending_since = None
            last_change_at = None

    return 0


def main() -> int:
    HERMES_HOME.mkdir(parents=True, exist_ok=True)
    if len(sys.argv) < 2:
        return loop()
    command = sys.argv[1]
    if command == "restore":
        return 0 if restore() else 1
    if command == "migrate":
        return 0 if migrate() else 1
    if command == "sync-once":
        try:
            sync_once()
            return 0
        except Exception as exc:
            write_status("error", f"Shutdown sync failed: {exc}")
            print(f"Hermes sync: shutdown sync failed: {exc}")
            return 1
    if command == "loop":
        return loop()
    print(f"Unknown command: {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
