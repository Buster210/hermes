#!/usr/bin/env python3
import sys
from pathlib import Path

p = Path("/opt/hermes-webui/server.py")
if not p.exists():
    print("webui quiet-poll patch: server.py absent, skipping")
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hermes-webui: quiet-poll-paths"
if sentinel in src:
    print("webui quiet-poll patch: already applied")
    sys.exit(0)

anchor = "    def log_request(self, code: str='-', size: str='-') -> None:\n"
if anchor not in src:
    print("webui quiet-poll patch: anchor not found (log_request signature changed) "
          "-- SKIPPING; webui logs will be noisy until the patch is re-anchored")
    sys.exit(0)

inject = (
    anchor +
    "        " + sentinel + "\n"
    "        _quiet_paths = {\n"
    "            '/api/health/agent', '/api/dashboard/status', '/api/dashboard/config',\n"
    "            '/api/sessions', '/api/profiles', '/api/profile/active',\n"
    "            '/api/onboarding/status', '/api/insights', '/api/system/health',\n"
    "            '/api/settings', '/api/projects', '/api/reasoning', '/api/models',\n"
    "            '/api/chat/stream/status', '/api/git-info', '/sw.js', '/health',\n"
    "        }\n"
    "        _quiet_prefixes = ('/static/', '/session/static/', '/assets/')\n"
    "        try:\n"
    "            _st = int(code) if str(code).isdigit() else 0\n"
    "        except Exception:\n"
    "            _st = 0\n"
    "        _qp = (getattr(self, 'path', '') or '').split('?', 1)[0]\n"
    "        if 200 <= _st < 400:\n"
    "            if _qp in _quiet_paths:\n"
    "                return\n"
    "            for _pref in _quiet_prefixes:\n"
    "                if _qp.startswith(_pref):\n"
    "                    return\n"
)
p.write_text(src.replace(anchor, inject, 1), encoding="utf-8")
print("webui quiet-poll patch: applied")
