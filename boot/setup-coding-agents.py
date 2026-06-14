#!/usr/bin/env python3
import json
import os
import pathlib


def _read_json(path):
    try:
        v = json.loads(pathlib.Path(path).read_text())
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}
home = pathlib.Path(os.environ["CODING_HOME"])

(home / ".claude").mkdir(parents=True, exist_ok=True)
sjson = home / ".claude" / "settings.json"
s = _read_json(sjson)
perms = s.setdefault("permissions", {})
if isinstance(perms, dict):
    perms.setdefault("defaultMode", "bypassPermissions")
env = s.setdefault("env", {})
if isinstance(env, dict):
    env.setdefault("DISABLE_AUTOUPDATER", "1")
sjson.write_text(json.dumps(s, indent=2))
gjson = home / ".claude.json"
g = _read_json(gjson)
g["hasCompletedOnboarding"] = True
gjson.write_text(json.dumps(g, indent=2))

ocdir = home / ".config" / "opencode"
ocdir.mkdir(parents=True, exist_ok=True)
ocjson = ocdir / "opencode.json"
cfg = _read_json(ocjson)
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("autoupdate", False)
perm = cfg.setdefault("permission", {})
if isinstance(perm, dict):
    perm.setdefault("edit", "allow")
    perm.setdefault("bash", "allow")
    perm.setdefault("webfetch", "allow")
model = os.environ.get("OC_MODEL", "").strip()
if model:
    cfg.setdefault("model", model)
ocjson.write_text(json.dumps(cfg, indent=2))
print(f"coding-agent setup: claude + opencode config seeded (opencode model: {model or 'default'})")
