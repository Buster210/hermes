---
title: Hermes Agent
emoji: 👁
colorFrom: purple
colorTo: pink
sdk: docker
pinned: false
license: apache-2.0
---

# Hermes Agent

Hugging Face Space running [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) with a Telegram gateway and Gemini backend.

## Required Environment Variables

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (from BotFather) |
| `GEMINI_API_KEY` | Google Gemini API key (up to 5 keys supported: `_1` through `_4`) |
| `HF_TOKEN` | (Optional) Hugging Face token for HF provider |

## Deployment

Push to a Hugging Face Space with `sdk: docker`. The Space auto-builds and runs the container.

## Build Locally

```bash
docker build -t hermes-agent .
docker run -p 7860:7860 --env-file .env hermes-agent
```
