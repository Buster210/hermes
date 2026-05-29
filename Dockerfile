# Merged deployment: Hermes router + Hermes WebUI on HF Spaces.
# Base: NousResearch Hermes Agent (Hermes CLI, gateway, dashboard, venv).

ARG HERMES_AGENT_VERSION=latest
FROM nousresearch/hermes-agent:${HERMES_AGENT_VERSION}

ARG WEBUI_REF=v0.51.252

USER root

# System deps + WebUI checkout + router.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    git \
    python3 \
    nodejs \
    npm \
    chromium \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libgbm1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxkbcommon0 \
    libx11-6 \
    libxext6 \
    libxfixes3 \
    libasound2 \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
        huggingface_hub hf_transfer pyyaml

# Clone WebUI; install deps into agent venv so imports resolve.
RUN git clone --depth 1 --branch ${WEBUI_REF} \
        https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
 && ( [ -f /opt/hermes-webui/requirements.txt ] \
      && /opt/hermes/.venv/bin/pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt \
      || true ) \
 && chown -R hermes:hermes /opt/hermes-webui

# Integration scripts (vendored from HuggingMes).
COPY --chown=hermes:hermes start.sh                       /opt/hermes/start.sh
COPY --chown=hermes:hermes health-server.js               /opt/hermes/health-server.js
COPY --chown=hermes:hermes hermes-sync.py                 /opt/hermes/hermes-sync.py
COPY --chown=hermes:hermes cloudflare-proxy-setup.py      /opt/hermes/cloudflare-proxy-setup.py
COPY --chown=hermes:hermes cloudflare-keepalive-setup.py  /opt/hermes/cloudflare-keepalive-setup.py

RUN chmod +x \
    /opt/hermes/start.sh \
    /opt/hermes/hermes-sync.py \
    /opt/hermes/cloudflare-proxy-setup.py \
    /opt/hermes/cloudflare-keepalive-setup.py

# Idempotent kanban migration patch (from HuggingMes).
RUN python3 - <<'PY'
from pathlib import Path
import sys
p = Path("/opt/hermes/hermes_cli/kanban_db.py")
if not p.exists():
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hermes-webui: idempotent-alter"
if sentinel in src:
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
if old in src:
    p.write_text(src.replace(old, new), encoding="utf-8")
    print("kanban patch: applied")
PY

# Silence high-frequency poll paths in logs (drowns HF Logs tab otherwise).
# Only drops 2xx — errors and streaming still log.
RUN python3 - <<'PY'
from pathlib import Path
import re
import sys

p = Path("/opt/hermes-webui/server.py")
if not p.exists():
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hermes-webui: quiet-poll-paths"
if sentinel in src:
    sys.exit(0)

old = (
    "    def log_request(self, code: str='-', size: str='-') -> None:\n"
    "        \"\"\"Structured JSON logs for each request.\"\"\"\n"
    "        import json as _json\n"
    "        duration_ms = round((time.time() - getattr(self, '_req_t0', time.time())) * 1000, 1)\n"
    "        record = _json.dumps({\n"
    "            'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),\n"
    "            'method': self.command or '-',\n"
    "            'path': self.path or '-',\n"
    "            'status': int(code) if str(code).isdigit() else code,\n"
    "            'ms': duration_ms,\n"
    "        })\n"
    "        print(f'[webui] {record}', flush=True)"
)

new = (
    "    _QUIET_POLL_PATHS = (  " + sentinel + "\n"
    "        '/api/health/agent', '/api/dashboard/status',\n"
    "        '/api/dashboard/config', '/api/sessions', '/api/profiles',\n"
    "        '/api/profile/active', '/api/onboarding/status',\n"
    "        '/api/insights', '/api/system/health',\n"
    "        '/api/settings', '/api/projects', '/api/reasoning',\n"
    "        '/api/models', '/api/chat/stream/status',\n"
    "        '/api/git-info', '/sw.js', '/health',\n"
    "    )\n"
    "    _QUIET_PREFIXES = ('/static/', '/session/static/', '/assets/')\n"
    "\n"
    "    def log_request(self, code: str='-', size: str='-') -> None:\n"
    "        \"\"\"Structured JSON logs for each request, skipping noisy polls.\"\"\"\n"
    "        # Always log non-2xx so 401/404/5xx remain visible.\n"
    "        try:\n"
    "            status_int = int(code) if str(code).isdigit() else 0\n"
    "        except Exception:\n"
    "            status_int = 0\n"
    "        path = (self.path or '').split('?', 1)[0]\n"
    "        if 200 <= status_int < 400:\n"
    "            if path in self._QUIET_POLL_PATHS:\n"
    "                return\n"
    "            for pref in self._QUIET_PREFIXES:\n"
    "                if path.startswith(pref):\n"
    "                    return\n"
    "        import json as _json\n"
    "        duration_ms = round((time.time() - getattr(self, '_req_t0', time.time())) * 1000, 1)\n"
    "        record = _json.dumps({\n"
    "            'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),\n"
    "            'method': self.command or '-',\n"
    "            'path': self.path or '-',\n"
    "            'status': int(code) if str(code).isdigit() else code,\n"
    "            'ms': duration_ms,\n"
    "        })\n"
    "        print(f'[webui] {record}', flush=True)"
)

if old in src:
    p.write_text(src.replace(old, new), encoding="utf-8")
    print("webui log-quiet patch: applied")
else:
    print("webui log-quiet patch: pattern not found, skipping")
PY

# hermes user needs write access for auto-updates.
RUN chown -R hermes:hermes /opt/hermes/.venv

# Keep hermes CLI on PATH for all shell types.
RUN echo 'export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"' \
    > /etc/profile.d/hermes-venv.sh

ENV HERMES_HOME=/opt/data \
    HERMES_APP_DIR=/opt/hermes \
    HERMES_WEBUI_REPO=/opt/hermes-webui \
    HERMES_AGENT_VERSION=${HERMES_AGENT_VERSION} \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

EXPOSE 7861

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD curl -fsS http://localhost:7861/health || exit 1

USER hermes
ENTRYPOINT ["/opt/hermes/start.sh"]
