# HuggingMes + Hermes WebUI — merged deployment for Hugging Face Spaces
# Base: NousResearch Hermes Agent (ships Hermes CLI, gateway, dashboard, Python venv)

ARG HERMES_AGENT_VERSION=latest
FROM nousresearch/hermes-agent:${HERMES_AGENT_VERSION}

ARG WEBUI_REF=master

USER root

# System deps (mirrors HuggingMes) + git/nodejs for WebUI checkout + router
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

# Clone nesquena/hermes-webui (install deps into the agent venv so imports resolve)
RUN git clone --depth 1 --branch ${WEBUI_REF} \
        https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
 && ( [ -f /opt/hermes-webui/requirements.txt ] \
      && /opt/hermes/.venv/bin/pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt \
      || true ) \
 && chown -R hermes:hermes /opt/hermes-webui

# HuggingMes-style integration scripts (vendored from somratpro/HuggingMes)
COPY --chown=hermes:hermes start.sh                       /opt/huggingmes/start.sh
COPY --chown=hermes:hermes health-server.js               /opt/huggingmes/health-server.js
COPY --chown=hermes:hermes hermes-sync.py                 /opt/huggingmes/hermes-sync.py
COPY --chown=hermes:hermes cloudflare-proxy-setup.py      /opt/huggingmes/cloudflare-proxy-setup.py
COPY --chown=hermes:hermes cloudflare-keepalive-setup.py  /opt/huggingmes/cloudflare-keepalive-setup.py

RUN chmod +x \
    /opt/huggingmes/start.sh \
    /opt/huggingmes/hermes-sync.py \
    /opt/huggingmes/cloudflare-proxy-setup.py \
    /opt/huggingmes/cloudflare-keepalive-setup.py

# Idempotent kanban migration patch (same workaround HuggingMes ships)
RUN python3 - <<'PY'
from pathlib import Path
import sys
p = Path("/opt/hermes/hermes_cli/kanban_db.py")
if not p.exists():
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# huggingmes-webui: idempotent-alter"
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

# Keep hermes CLI on PATH for all shell types (login/interactive/non-interactive)
RUN echo 'export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"' \
    > /etc/profile.d/hermes-venv.sh

ENV HERMES_HOME=/opt/data \
    HUGGINGMES_APP_DIR=/opt/huggingmes \
    HERMES_WEBUI_REPO=/opt/hermes-webui \
    HERMES_AGENT_VERSION=${HERMES_AGENT_VERSION} \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

EXPOSE 7861

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD curl -fsS http://localhost:7861/health || exit 1

USER hermes
CMD ["/opt/huggingmes/start.sh"]
