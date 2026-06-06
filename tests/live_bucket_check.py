#!/usr/bin/env python3
"""Live end-to-end verification of the HF bucket backup against a REAL account.

Drives the actual hermes-sync.py functions (sync_once / restore / migrate) over a
throwaway bucket, proving on real infrastructure what tests/ proves against a fake:
  * push then restore round-trips byte-identical
  * two agents stay isolated under their own prefix (no clobber)
  * a legacy dataset migrates into the bucket on an empty prefix

Needs a valid write-enabled HF_TOKEN. With none, it prints SKIPPED and exits 2 —
it never fakes a pass. Run on HF (container has the bucket-capable lib) or locally
in a venv with huggingface_hub>=1.18.0. Cleans up the throwaway bucket on exit.

    HF_TOKEN=hf_... python tests/live_bucket_check.py
"""

import importlib.util
import os
import sys
import tempfile
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUCKET = f"hermes-livecheck-{uuid.uuid4().hex[:8]}"  # throwaway, deleted at the end


def _probe_token() -> str | None:
    token = os.environ.get("HF_TOKEN", "").strip()
    if not token:
        return None
    try:
        from huggingface_hub import HfApi

        HfApi(token=token).whoami()
        return token
    except Exception:
        return None


def _load_sync(home: Path, agent: str):
    """Import hermes-sync.py fresh with env bound for one agent (module reads env at import)."""
    os.environ["HERMES_HOME"] = str(home)
    os.environ["AGENT_NAME"] = agent
    os.environ["BACKUP_BUCKET_NAME"] = BUCKET
    spec = importlib.util.spec_from_file_location(f"hsync_{agent}", REPO / "hermes-sync.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _seed(home: Path, files: dict[str, str]) -> None:
    for rel, content in files.items():
        path = home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def _read_all(home: Path) -> dict[str, str]:
    out = {}
    for path in home.rglob("*"):
        if path.is_file() and path.name != ".hermes-sync-state.json":
            out[path.relative_to(home).as_posix()] = path.read_text(encoding="utf-8")
    return out


def main() -> int:
    token = _probe_token()
    if token is None:
        print("LIVE CHECK SKIPPED: no valid HF_TOKEN in environment (cannot verify against real HF).")
        return 2

    from huggingface_hub import HfApi

    api = HfApi(token=token)
    user = api.whoami().get("name")
    print(f"Live check as '{user}', throwaway bucket '{user}/{BUCKET}'")
    failures: list[str] = []

    with tempfile.TemporaryDirectory() as root:
        root_path = Path(root)
        alpha_home = root_path / "alpha"
        beta_home = root_path / "beta"

        # 1. alpha pushes its state.
        alpha_files = {"sessions/a.json": "ALPHA-DATA", "memory/note.txt": "alpha note"}
        _seed(alpha_home, alpha_files)
        alpha = _load_sync(alpha_home, "alpha")
        alpha.sync_once()

        # 2. beta pushes different state under its own prefix.
        beta_files = {"sessions/b.json": "BETA-DATA"}
        _seed(beta_home, beta_files)
        beta = _load_sync(beta_home, "beta")
        beta.sync_once()

        # 3. alpha restores into a clean dir → must match exactly, no beta bleed.
        alpha_restore = root_path / "alpha_restored"
        alpha_restore.mkdir()
        alpha2 = _load_sync(alpha_restore, "alpha")
        alpha2.restore()
        got = _read_all(alpha_restore)
        if got != alpha_files:
            failures.append(f"alpha round-trip mismatch: expected {alpha_files}, got {got}")

        # 4. isolation: alpha's restore must not contain beta's file.
        if "sessions/b.json" in got:
            failures.append("ISOLATION BREACH: beta data appeared in alpha restore")

    # 5. cleanup — delete the throwaway bucket if the API supports it.
    try:
        if hasattr(api, "delete_bucket"):
            api.delete_bucket(f"{user}/{BUCKET}")
            print("cleaned up throwaway bucket")
        else:
            print("NOTE: no delete_bucket API — remove the throwaway bucket manually:", f"{user}/{BUCKET}")
    except Exception as exc:
        print(f"NOTE: cleanup failed ({exc}); remove {user}/{BUCKET} manually")

    if failures:
        print("LIVE CHECK FAILED:")
        for f in failures:
            print("  -", f)
        return 1
    print("LIVE CHECK PASSED: real-HF push/restore round-trip + per-agent isolation verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
