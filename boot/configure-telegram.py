#!/usr/bin/env python3
import os
from pathlib import Path

import yaml

path = Path(os.environ["HERMES_HOME"]) / "config.yaml"
try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
except FileNotFoundError:
    config = {}

telegram = config.setdefault("platforms", {}).setdefault("telegram", {})
telegram.setdefault("enabled", True)
extra = telegram.setdefault("extra", {})
if os.environ.get("TELEGRAM_BASE_URL"):
    extra["base_url"] = os.environ["TELEGRAM_BASE_URL"]
    extra["base_file_url"] = os.environ.get("TELEGRAM_BASE_FILE_URL") or os.environ["TELEGRAM_BASE_URL"]
if os.environ.get("TELEGRAM_ALLOWED_USERS"):
    config.setdefault("telegram", {}).setdefault("allow_from", [
        item.strip()
        for item in os.environ["TELEGRAM_ALLOWED_USERS"].split(",")
        if item.strip()
    ])

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
path.chmod(0o600)
