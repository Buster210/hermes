FROM python:3.14-slim

LABEL org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent" \
      org.opencontainers.image.description="Hermes Agent - Telegram Gateway for Hugging Face Spaces" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libatomic1 \
    tmate \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash hermes

# Baked so hermes skips its ~120MB runtime download at boot.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSL https://nodejs.org/dist/latest/SHASUMS256.txt -o SHASUMS256.txt; \
    fname="$(grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-linux-${node_arch}\.tar\.xz" SHASUMS256.txt | head -1)"; \
    test -n "$fname"; \
    curl -fsSLO "https://nodejs.org/dist/latest/$fname"; \
    grep "  $fname\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "$fname" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "$fname" SHASUMS256.txt; \
    BUN_INSTALL=/usr/local curl -fsSL https://bun.sh/install | bash; \
    ln -sf /root/.bun/bin/bun /usr/local/bin/bun; \
    rm -rf /root/.bun/install/cache; \
    node --version && bun --version

# System Chromium (not CFT) so one image works on amd64 + arm64.
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PATH="/root/.bun/bin:${PATH}"
ARG AGENT_BROWSER_SPEC="agent-browser@^0.26.0"
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends chromium; \
    bun install -g "${AGENT_BROWSER_SPEC}"; \
    command -v agent-browser; chromium --version; \
    rm -rf /var/lib/apt/lists/* /tmp/*

# HERMES_VERSION pins the released hermes-agent (PyPI) — bump deliberately, never floats to latest.
# CACHEBUST busts only this layer so cached node/browser layers stay reusable.
ARG HERMES_VERSION=0.15.2
ARG CACHEBUST=
RUN echo "hermes build ${CACHEBUST}" && \
    pip install --no-cache-dir "hermes-agent[messaging]${HERMES_VERSION:+==${HERMES_VERSION}}" websockets

USER hermes
WORKDIR /home/hermes/app
# Hardens Chromium for restrictive seccomp + small /dev/shm.
ENV PATH="/home/hermes/.local/bin:${PATH}" \
    HERMES_SKIP_NODE_BOOTSTRAP=1 \
    AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"

COPY --chown=hermes:hermes agents/ /home/hermes/app/agents/
COPY --chown=hermes:hermes --chmod=0755 entrypoint.sh .

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:7860/').status==200 else 1)" 2>/dev/null || exit 1

EXPOSE 7860
ENTRYPOINT ["./entrypoint.sh"]
