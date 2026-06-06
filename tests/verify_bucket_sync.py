#!/usr/bin/env python3
"""Network-free logic proof for hermes-sync.py bucket backup.

Monkeypatches the huggingface_hub bucket calls (create_bucket / sync_bucket /
list_bucket_tree) and snapshot_download with a local-filesystem fake "remote",
then exercises hermes-sync end-to-end:

  (a) two agents (alpha/beta) sync to their OWN prefix without clobbering
  (b) restore round-trips byte-identical
  (c) excludes (.git, __pycache__, *.log, >50MB, .env) are NOT uploaded
  (d) marker/fingerprint short-circuit skips a no-op sync
  (e) migration: empty bucket prefix imports the legacy dataset and seeds the prefix

Run: /tmp/hbk/bin/python tests/verify_bucket_sync.py
"""

import importlib.util
import os
import shutil
import tempfile
from pathlib import Path

from huggingface_hub.errors import RepositoryNotFoundError

REPO_ROOT = Path(__file__).resolve().parent.parent
SYNC_PATH = REPO_ROOT / "hermes-sync.py"

_FAILURES: list[str] = []
_LOAD_COUNTER = 0


def check(name: str, ok: bool) -> None:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        _FAILURES.append(name)


def _copytree_merge(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for path in src.rglob("*"):
        rel = path.relative_to(src)
        target = dst / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def _parse_uri(uri: str) -> tuple[str, str]:
    """hf://buckets/<ns>/<bucket>/<prefix...> -> (bucket_id, prefix_relpath)."""
    rest = uri[len("hf://buckets/"):]
    parts = rest.split("/")
    bucket_id = "/".join(parts[:2])
    prefix = "/".join(parts[2:])
    return bucket_id, prefix


class FakeRemote:
    """Local-FS stand-in for HF Storage Buckets + the legacy dataset."""

    def __init__(self, remote_root: Path, dataset_root: Path):
        self.remote_root = remote_root
        self.dataset_root = dataset_root
        self.upload_count = 0
        self.download_count = 0

    # --- bucket API surface (matches HfApi method signatures) ---
    def create_bucket(self, bucket_id, *, private=None, exist_ok=False, **kw):
        path = self.remote_root / bucket_id
        if path.exists() and not exist_ok:
            raise RuntimeError(f"bucket {bucket_id} already exists")
        path.mkdir(parents=True, exist_ok=True)

    def sync_bucket(self, source=None, dest=None, *, delete=False, **kw):
        if source.startswith("hf://buckets/"):
            # download: remote prefix -> local dest
            bucket_id, prefix = _parse_uri(source)
            remote_path = self.remote_root / bucket_id / prefix
            self.download_count += 1
            if remote_path.exists():
                _copytree_merge(remote_path, Path(dest))
        else:
            # upload: local source -> remote prefix
            bucket_id, prefix = _parse_uri(dest)
            remote_path = self.remote_root / bucket_id / prefix
            self.upload_count += 1
            if delete and remote_path.exists():
                shutil.rmtree(remote_path)
            _copytree_merge(Path(source), remote_path)

    def list_bucket_tree(self, bucket_id, prefix=None, *, recursive=None, **kw):
        base = self.remote_root / bucket_id / (prefix or "")
        if not base.exists():
            return
        for path in base.rglob("*"):
            if path.is_file():
                yield path

    # --- dataset migration source ---
    def snapshot_download(self, repo_id=None, repo_type=None, token=None, local_dir=None, **kw):
        src = self.dataset_root / repo_id
        if not src.exists():
            raise RepositoryNotFoundError(f"dataset {repo_id} not found")
        _copytree_merge(src, Path(local_dir))
        return str(local_dir)


def load_sync_module(remote: FakeRemote, **env) -> object:
    global _LOAD_COUNTER
    _LOAD_COUNTER += 1
    os.environ["HF_TOKEN"] = "faketoken"
    os.environ["HF_USERNAME"] = "testns"
    os.environ.pop("SPACE_ID", None)
    os.environ.pop("SPACE_HOST", None)
    os.environ.pop("SYNC_INCLUDE_ENV", None)
    for key, value in env.items():
        os.environ[key] = value

    spec = importlib.util.spec_from_file_location(f"hermes_sync_{_LOAD_COUNTER}", SYNC_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # Swap the real HF surface for the shared fake remote.
    mod.HF_API = remote
    mod.snapshot_download = remote.snapshot_download
    return mod


def seed_home(home: Path, marker_text: str) -> None:
    """Populate a HERMES_HOME with included files + every exclude category."""
    (home / "sessions").mkdir(parents=True, exist_ok=True)
    (home / "memory").mkdir(parents=True, exist_ok=True)
    (home / "sessions" / "chat.json").write_text(f'{{"agent":"{marker_text}"}}', encoding="utf-8")
    (home / "memory" / "notes.txt").write_text(f"notes for {marker_text}", encoding="utf-8")
    # excludes
    (home / ".git").mkdir(exist_ok=True)
    (home / ".git" / "config").write_text("[core]\n", encoding="utf-8")
    (home / "__pycache__").mkdir(exist_ok=True)
    (home / "__pycache__" / "x.pyc").write_text("bytecode", encoding="utf-8")
    (home / "app.log").write_text("log line\n", encoding="utf-8")
    (home / ".env").write_text("SECRET=topsecret\n", encoding="utf-8")
    big = home / "big.bin"
    with big.open("wb") as fh:
        fh.truncate(51 * 1024 * 1024)  # > 50MB cap


def rel_file_set(root: Path) -> set[str]:
    return {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}


def trees_byte_identical(a: Path, b: Path) -> bool:
    if rel_file_set(a) != rel_file_set(b):
        return False
    for rel in rel_file_set(a):
        if (a / rel).read_bytes() != (b / rel).read_bytes():
            return False
    return True


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="hermes-verify-"))
    remote = FakeRemote(work / "remote", work / "datasets")
    remote.remote_root.mkdir(parents=True, exist_ok=True)
    remote.dataset_root.mkdir(parents=True, exist_ok=True)

    bucket_id = "testns/hermes-backup"
    rroot = remote.remote_root

    # ---- (a) + (c): two agents sync to own prefix; excludes filtered ----
    print("Test (a)/(c): per-agent prefixes + exclude filtering")
    alpha_home = work / "alpha" / ".hermes"
    beta_home = work / "beta" / ".hermes"
    seed_home(alpha_home, "alpha")
    seed_home(beta_home, "beta")

    m_alpha = load_sync_module(remote, AGENT_NAME="alpha", HERMES_HOME=str(alpha_home),
                               MIGRATE_FROM_DATASET="false")
    m_alpha.sync_once()
    m_beta = load_sync_module(remote, AGENT_NAME="beta", HERMES_HOME=str(beta_home),
                              MIGRATE_FROM_DATASET="false")
    m_beta.sync_once()

    alpha_prefix = rroot / bucket_id / "alpha"
    beta_prefix = rroot / bucket_id / "beta"
    alpha_uploaded = rel_file_set(alpha_prefix)
    beta_uploaded = rel_file_set(beta_prefix)

    check("alpha prefix has alpha's content", '{"agent":"alpha"}' == (alpha_prefix / "sessions/chat.json").read_text())
    check("beta prefix has beta's content", '{"agent":"beta"}' == (beta_prefix / "sessions/chat.json").read_text())
    check("alpha did not clobber beta (distinct content)", alpha_uploaded == beta_uploaded and
          (alpha_prefix / "memory/notes.txt").read_text() != (beta_prefix / "memory/notes.txt").read_text())
    check("included files uploaded", {"sessions/chat.json", "memory/notes.txt"} <= alpha_uploaded)
    check("exclude .git not uploaded", not any(".git" in f for f in alpha_uploaded))
    check("exclude __pycache__ not uploaded", not any("__pycache__" in f for f in alpha_uploaded))
    check("exclude *.log not uploaded", "app.log" not in alpha_uploaded)
    check("exclude .env not uploaded", ".env" not in alpha_uploaded)
    check("exclude >50MB not uploaded", "big.bin" not in alpha_uploaded)

    # ---- (b): restore round-trips byte-identical ----
    print("Test (b): restore round-trip byte-identical")
    alpha_restored = work / "alpha_restored" / ".hermes"
    m_restore = load_sync_module(remote, AGENT_NAME="alpha", HERMES_HOME=str(alpha_restored),
                                 MIGRATE_FROM_DATASET="false")
    m_restore.restore()
    # Canonical uploaded set = what create_snapshot_dir would produce from the source.
    staging = Path(m_alpha.create_snapshot_dir(alpha_home))
    try:
        check("restored tree byte-identical to uploaded snapshot",
              trees_byte_identical(staging, alpha_restored))
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    # ---- (d): marker/fingerprint short-circuit skips no-op sync ----
    print("Test (d): no-op short-circuit")
    fp, marker = m_alpha.sync_once()  # fresh marker/fp for unchanged alpha_home
    uploads_before = remote.upload_count
    fp2, marker2 = m_alpha.sync_once(fp, marker)
    check("no upload on unchanged tree", remote.upload_count == uploads_before)
    check("short-circuit returns same fingerprint", fp2 == fp)

    # ---- (e): migration from legacy dataset on empty prefix ----
    print("Test (e): legacy dataset -> bucket migration")
    # Seed a legacy dataset for namespace testns / hermes-backup.
    ds = remote.dataset_root / "testns/hermes-backup"
    (ds / "sessions").mkdir(parents=True, exist_ok=True)
    (ds / "sessions" / "old.json").write_text('{"legacy":true}', encoding="utf-8")
    (ds / "memory").mkdir(parents=True, exist_ok=True)
    (ds / "memory" / "old.txt").write_text("legacy memory", encoding="utf-8")

    gamma_home = work / "gamma" / ".hermes"
    m_gamma = load_sync_module(remote, AGENT_NAME="gamma", HERMES_HOME=str(gamma_home),
                               MIGRATE_FROM_DATASET="true")
    m_gamma.restore()

    check("migration landed dataset data in HERMES_HOME",
          (gamma_home / "sessions/old.json").exists() and (gamma_home / "memory/old.txt").exists())
    gamma_prefix = rroot / bucket_id / "gamma"
    check("migration seeded the bucket prefix",
          (gamma_prefix / "sessions/old.json").exists() and (gamma_prefix / "memory/old.txt").exists())
    check("gamma did not touch alpha/beta prefixes",
          rel_file_set(alpha_prefix) == alpha_uploaded and rel_file_set(beta_prefix) == beta_uploaded)

    shutil.rmtree(work, ignore_errors=True)

    print()
    if _FAILURES:
        print(f"RESULT: FAILED ({len(_FAILURES)} check(s)): {_FAILURES}")
        return 1
    print("RESULT: ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
