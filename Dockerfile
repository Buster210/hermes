ARG HERMES_AGENT_REF=nousresearch/hermes-agent@sha256:9ad3b04ec916ea2c2da22358fd43b024c788d74073210695af88bfc2e63869b4
ARG WEBUI_REF=v0.51.410

FROM ${HERMES_AGENT_REF}

ARG WEBUI_REF

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq git python3 nodejs npm chromium tmate tmux zsh fzf \
    zoxide bat eza gnupg neovim ffmpeg poppler-utils libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libdrm2 libgbm1 libxcomposite1 libxdamage1 libxrandr2 \
    libxkbcommon0 libx11-6 libxext6 libxfixes3 fonts-dejavu-core fonts-liberation \
    fonts-noto-color-emoji \
    && (apt-get install -y --no-install-recommends libasound2 2>/dev/null \
        || apt-get install -y --no-install-recommends libasound2t64 2>/dev/null || true) \
    && uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir "huggingface_hub>=1.18.0" hf_transfer pyyaml

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*

ENV NPM_CONFIG_PREFIX=/opt/hermes/npm-global
RUN mkdir -p /opt/hermes/npm-global

ENV UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin
RUN npm install -g opencode-ai@latest npm@latest \
 && npm cache clean --force \
 && export HOME=/opt/claude-home && mkdir -p "$HOME" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && ln -sf  "$HOME/.local/bin/claude"   /usr/local/bin/claude \
 && ln -sfn "$HOME/.local/share/claude" /usr/local/share/claude \
 && chmod -R a+rX /opt/claude-home/.local \
 && claude --version \
 && uv tool install code-review-graph \
 && code-review-graph --help >/dev/null

RUN export ZSH=/opt/oh-my-zsh \
 && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc \
 && git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "$ZSH/custom/themes/powerlevel10k" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH/custom/plugins/zsh-autosuggestions" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH/custom/plugins/zsh-syntax-highlighting" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-completions "$ZSH/custom/plugins/zsh-completions" \
 && git clone --depth 1 https://github.com/Aloxaf/fzf-tab "$ZSH/custom/plugins/fzf-tab" \
 && chown -R hermes:hermes "$ZSH" \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && grep -qxF /usr/bin/zsh /etc/shells 2>/dev/null || echo /usr/bin/zsh >> /etc/shells \
 && usermod -s /usr/bin/zsh hermes

RUN git clone --depth 1 --branch ${WEBUI_REF} https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
 && if [ -f /opt/hermes-webui/requirements.txt ]; then \
      uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir -r /opt/hermes-webui/requirements.txt; \
    fi \
 && chown -R hermes:hermes /opt/hermes-webui

COPY --chown=hermes:hermes start.sh  /opt/hermes/start.sh
COPY --chown=hermes:hermes shell/    /opt/hermes/shell/
COPY --chown=hermes:hermes hooks/    /opt/hermes/hooks/
COPY --chown=hermes:hermes sync/     /opt/hermes/sync/
COPY --chown=hermes:hermes network/  /opt/hermes/network/
COPY --chown=hermes:hermes server/   /opt/hermes/server/
COPY --chown=hermes:hermes boot/     /opt/hermes/boot/

RUN chmod +x /opt/hermes/start.sh /opt/hermes/sync/hermes-sync.py \
    /opt/hermes/network/tmate-tools.sh /opt/hermes/network/cloudflare-proxy-setup.py \
    /opt/hermes/network/cloudflare-keepalive-setup.py /opt/hermes/boot/*.py \
 && ln -sf /opt/hermes/network/tmate-tools.sh /usr/local/bin/tmate-new \
 && ln -sf /opt/hermes/network/tmate-tools.sh /usr/local/bin/tmate-ls \
 && ln -sf /opt/hermes/network/tmate-tools.sh /usr/local/bin/tmate-kill \
 && chown -R hermes:hermes /opt/hermes/.venv /opt/hermes/npm-global \
 && chown hermes:hermes /home \
 && echo 'export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"' \
    > /etc/profile.d/hermes-venv.sh \
 && python3 /opt/hermes/boot/patch-kanban-db.py \
 && python3 /opt/hermes/boot/patch-quiet-poll.py

ENV HERMES_HOME=/opt/data HERMES_APP_DIR=/opt/hermes \
    HERMES_WEBUI_REPO=/opt/hermes-webui \
    HERMES_WEBUI_TRUST_FORWARDED_HOST=1 PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium SHELL=/usr/bin/zsh \
    DISABLE_AUTOUPDATER=1 PATH="/opt/hermes/npm-global/bin:${PATH}"

EXPOSE 7861
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s CMD curl -fsS http://localhost:7861/health || exit 1

USER hermes
ENTRYPOINT ["/opt/hermes/start.sh"]
