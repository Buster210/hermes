#!/usr/bin/env python3
import sys
from pathlib import Path

try:
    p = Path("/opt/hermes/hermes_cli/kanban_db.py")
    if not p.exists():
        print("kanban patch: file not found, skipping")
        sys.exit(0)

    src = p.read_text(encoding="utf-8", errors="replace")
    sentinel = "# hermes-webui: idempotent-alter"
    if sentinel in src:
        print("kanban patch: already applied, skipping")
        sys.exit(0)

    old = (
        '    conn.execute(\n'
        '        "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '        "INTEGER NOT NULL DEFAULT 0"\n'
        '    )'
    )
    new = (
        f'    try:  {sentinel}\n'
        '        conn.execute(\n'
        '            "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '            "INTEGER NOT NULL DEFAULT 0"\n'
        '        )\n'
        '    except Exception:\n'
        '        pass'
    )

    if old not in src:
        print("kanban patch: pattern not found, may be fixed upstream, skipping")
        sys.exit(0)

    p.write_text(src.replace(old, new), encoding="utf-8")
    print("kanban patch: applied")
except Exception as e:
    print(f"kanban patch: error ({e}), skipping", file=sys.stderr)
