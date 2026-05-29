FROM python:3.11-slim

LABEL org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent" \
      org.opencontainers.image.description="Hermes Agent - Telegram Gateway for Hugging Face Spaces" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    tmate \
    openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash hermes

ARG HERMES_COMMIT=main
RUN curl -fsSL "https://github.com/NousResearch/hermes-agent/archive/${HERMES_COMMIT}.tar.gz" -o /tmp/hermes.tar.gz \
    && pip install --no-cache-dir "/tmp/hermes.tar.gz[messaging]" \
    && rm /tmp/hermes.tar.gz

USER hermes
WORKDIR /home/hermes/app
ENV PATH="/home/hermes/.local/bin:${PATH}"

COPY --chown=hermes:hermes entrypoint.sh .
RUN chmod +x entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep -f "hermes" > /dev/null || exit 1

EXPOSE 7860
ENTRYPOINT ["./entrypoint.sh"]
