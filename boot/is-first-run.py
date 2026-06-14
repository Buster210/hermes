#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

state = Path(os.environ["HERMES_HOME"]) / ".hermes" / "keys-state.json"
try:
    done = json.loads(state.read_text(encoding="utf-8")).get("first_run_done") is True
except Exception:
    done = False
sys.exit(0 if done else 1)
