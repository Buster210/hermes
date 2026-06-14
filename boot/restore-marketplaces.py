#!/usr/bin/env python3
import json
import os
import sys

km, mdir = sys.argv[1], sys.argv[2]
try:
    with open(km) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
entries = data.get("marketplaces", data) if isinstance(data, dict) else {}
if not isinstance(entries, dict):
    sys.exit(0)
for name, meta in entries.items():
    if not isinstance(meta, dict):
        continue
    src = meta.get("source") or meta.get("repo") or meta.get("url")
    if src and not os.path.isdir(os.path.join(mdir, name)):
        print(src)
