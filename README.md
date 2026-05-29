---
title: HuggingMes Hermes WebUI
emoji: 🪽
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7861
pinned: true
license: mit
---

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE) [![HF Spaces](https://img.shields.io/badge/%F0%9F%A4%97-HF%20Spaces-blue)](https://huggingface.co/spaces/22f2001388/hermes) [![Docker](https://img.shields.io/badge/docker-ready-blue)](./Dockerfile) [![Upstream](https://img.shields.io/badge/upstream-22f2001388%2Fhermes-lightgrey)](https://github.com/22f2001388/hermes)

Run your own AI agent with a chat interface on Hugging Face Spaces — for free.

> **This is a fork** of four open-source projects stitched into a single Hugging Face Space. Full attribution in [Credits](#credits); license details in [`NOTICE`](./NOTICE).

---

## Features

- **Chat UI** — Three-panel Hermes WebUI with SSE streaming, slash commands, profile management, theme system
- **AI agent** — Powered by [Hermes Agent](https://github.com/NousResearch/hermes-agent): persistent memory, multi-provider LLM routing, cron jobs, skills
- **OpenAI-compatible API** — Expose your agent at `/v1/*` from any OpenAI SDK client
- **Telegram bridge** — Chat with Hermes from Telegram (works on private Spaces via Cloudflare proxy)
- **Free persistence** — Chats, memory, settings, profiles all backed up to a private HF Dataset
- **Single-token auth** — One `GATEWAY_TOKEN` for the UI and the API
- **One-click deploy** — Duplicate the Space, add secrets, wait 5 minutes
- **MCP support** — Plug in [Model Context Protocol](https://modelcontextprotocol.io/) servers for tools, filesystem, and more

## Table of Contents

- [Features](#features)
- [Table of Contents](#table-of-contents)
- [Quick Setup (5 minutes)](#quick-setup-5-minutes)
  - [1. Duplicate the Space](#1-duplicate-the-space)
  - [2. Add Your Secrets](#2-add-your-secrets)
  - [3. Add an AI Provider](#3-add-an-ai-provider)
  - [4. Start It Up](#4-start-it-up)
- [What You Get](#what-you-get)
- [Your Data Is Safe](#your-data-is-safe)
- [Common Issues](#common-issues)
- [🔧 Advanced Setup \& Technical Details](#-advanced-setup--technical-details)
  - [Optional Secrets (Power Users)](#optional-secrets-power-users)
  - [Configure LLM Provider via Config Editor](#configure-llm-provider-via-config-editor)
  - [Using the API from Code](#using-the-api-from-code)
  - [Adding MCP Servers](#adding-mcp-servers)
  - [Persistence Details](#persistence-details)
  - [Architecture](#architecture)
  - [Telegram on HF Spaces (webhook vs polling)](#telegram-on-hf-spaces-webhook-vs-polling)
    - [⚠️ Private Spaces must use `TELEGRAM_MODE=polling`](#️-private-spaces-must-use-telegram_modepolling)
    - [Why Telegram needs the Cloudflare proxy at all](#why-telegram-needs-the-cloudflare-proxy-at-all)
    - [Required keys for Telegram on HF](#required-keys-for-telegram-on-hf)
  - [Local Testing](#local-testing)
  - [Reproducing the HF environment locally (`run-local-hf.sh`)](#reproducing-the-hf-environment-locally-run-local-hfsh)
  - [Extended Troubleshooting](#extended-troubleshooting)
- [Credits](#credits)
- [License](#license)

---

## Quick Setup (5 minutes)

### 1. Duplicate the Space

[![Duplicate this Space](https://huggingface.co/datasets/huggingface/badges/resolve/main/duplicate-this-space-xl.svg)](https://huggingface.co/spaces/22f2001388/hermes?duplicate=true)

Click the badge above, name your space → pick **CPU Basic (Free)** → and keep it public (otherwise the `.hf.space` URLs won't work).

### 2. Add Your Secrets

Go to **Settings → Variables and secrets** in your new Space and add these:

| Secret | What It's For | How to Get It |
|--------|---------------|---------------|
| `GATEWAY_TOKEN` | Your password for logging into the chat | Make up any strong password |
| `HF_TOKEN` | Saves your chats and settings so they don't disappear | [Go here](https://huggingface.co/settings/tokens) → Create new token → Pick "write" |
| `CLOUDFLARE_WORKERS_TOKEN` | Keeps your Space awake and lets Telegram work | [Create a token here](https://dash.cloudflare.com/profile/api-tokens) → choose the **Edit Cloudflare Workers** template |

### 3. Add an AI Provider

Your agent needs an AI model to talk to. Add one of these API keys as a secret (or configure later in the dashboard):

| Secret | Provider |
|--------|----------|
| `OPENAI_API_KEY` | OpenAI (GPT models) |
| `ANTHROPIC_API_KEY` | Anthropic (Claude models) |
| `MOONSHOT_API_KEY` | Moonshot / Kimi |
| `GEMINI_API_KEY` | Google Gemini |

Or configure manually later at `/hm/app/config` inside your Space.

### 4. Start It Up

Hit **Restart this Space** in Hugging Face. Wait 5–8 minutes for the first build.

When you see this in the Logs tab, you're ready:

```text
HuggingMes + Hermes WebUI router listening on 0.0.0.0:7861
```

Open your Space URL (`https://your-name.hf.space`) in a **new tab**, enter your `GATEWAY_TOKEN`, and start chatting. The Hermes Dashboard is available at `/hm/app` (e.g. `https://22f2001388-hermes.hf.space/hm/app`).


> **Pro tip:** Bookmark the direct `*.hf.space` URL — it works better on mobile than the Hugging Face embed.
>
> **Want it on your phone?** Use your Space URL (`https://your-name.hf.space`) on Android — install it as a Progressive Web App (PWA) for a native-feeling experience, or just use the URL in any browser for normal chat.

---

## What You Get

| URL | What It Is |
|--------|------------|
| `/` | **Chat UI** — main interface for talking to your agent |
| `/hm` | Status dashboard — see what's running |
| `/hm/app/` | Settings — add AI models, set up cron jobs, manage profiles |
| `/v1/*` | API endpoint — connect other apps to your agent |
| `/telegram` | Telegram bot (if you added `TELEGRAM_BOT_TOKEN`) |

---

## Your Data Is Safe

When `HF_TOKEN` is set:
- All your chats, files, settings, and agent memory are backed up to a **private** Hugging Face Dataset within seconds of each change (change-driven, capped at 60 s)
- If the Space restarts, everything comes back exactly as you left it

---

## Common Issues

| Problem | Fix |
|---------|-----|
| Login keeps looping | Open the Space URL in a new tab (Hugging Face iframe blocks cookies) |
| Space goes to sleep after a few hours | Make sure `CLOUDFLARE_WORKERS_TOKEN` is set |
| Agent doesn't reply to questions | Check that you added an AI provider API key |
| Dashboard shows blank pages | Hard-refresh and clear service workers in browser dev tools |

For deeper troubleshooting (build failures, Telegram, Cloudflare, sync issues), see [Extended Troubleshooting](#extended-troubleshooting) in the [Advanced Setup](#-advanced-setup--technical-details) section.

---

## 🔧 Advanced Setup & Technical Details

> **Skip this section if you just want to chat.** The steps above are enough to get started. This part is for developers, power users, and anyone who wants to customize or understand the internals.

### Optional Secrets (Power Users)

| Secret | What It Does |
|--------|--------------|
| `CLOUDFLARE_ACCOUNT_ID` | Explicit Cloudflare account ID if you have multiple |
| `TELEGRAM_BOT_TOKEN` | Enables the Telegram bridge so you can chat with Hermes from Telegram |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated numeric Telegram user IDs allowed to use the bot |
| `PRIMARY_UI` | Controls what `/` shows. Default `webui` (chat UI). Set to `dashboard` to swap in the HuggingMes status page. |
| `SYNC_INTERVAL` | Backup cadence in seconds (default 600, range 60–86400) |
| `HERMES_AGENT_VERSION` | Pin the upstream Hermes Agent base image to a specific tag for reproducibility (default `latest`) |
| `BACKUP_DATASET_NAME` | Name of the private HF Dataset used for persistence (default `huggingmes-backup`) |

### Configure LLM Provider via Config Editor

> ### ⚠️ Provider keys go in HF Space Secrets, not the dashboard's Env tab
>
> The Hermes dashboard exposes an "Env" editor that writes to `/opt/data/.env`
> inside the container. **That file is *not* backed up to your HF Dataset.**
> On every Space sleep / rebuild the container's filesystem is wiped, the
> `.env` is gone, and your `OLLAMA_API_KEY` / `OPENROUTER_API_KEY` /
> `ANTHROPIC_API_KEY` / etc. disappear with it. The Space then 500s on the
> first chat with `Provider 'X' is set in config.yaml but no API key was
> found`.
>
> **Always add provider keys as HF Space Secrets** (Settings → Variables and
> secrets → New secret). HF injects them as env vars at boot, never writes
> them to disk on the Space, and they survive every restart.
>
> Use the dashboard's Env tab only for non-secret tweaks. The status page's
> Backup tile will show a yellow warning whenever it detects keys sitting in
> the ephemeral `.env` so you don't have to remember this on your own.
>
> If you accept the security tradeoff and want `.env` backed up anyway, set
> `SYNC_INCLUDE_ENV=1` as a Space Variable. The dataset is private, but a
> leak of that dataset URL is then a leak of every key in `.env`.

If you prefer not to add API keys as HF Secrets, you can configure providers directly in Hermes after the Space starts:

1. Open `/hm/app/config` in your Space
2. Add your provider under the `llm` section:

```yaml
llm:
  openai:
    api_key: "${OPENAI_API_KEY}"
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
  moonshot:
    api_key: "${MOONSHOT_API_KEY}"
    base_url: "https://api.moonshot.cn/v1"
```

If you set the API keys as HF Secrets, you can reference them with `${VAR_NAME}` as shown above. Hermes supports many providers — see the [Hermes Agent docs](https://github.com/NousResearch/hermes-agent) for the full list.

### Using the API from Code

Your Space exposes an OpenAI-compatible API at `/v1/*`:

```shell
curl https://<you>-<name>.hf.space/v1/chat/completions \
  -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hermes",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<you>-<name>.hf.space/v1",
    api_key="<your GATEWAY_TOKEN>",
)
resp = client.chat.completions.create(
    model="hermes",
    messages=[{"role": "user", "content": "hello"}],
)
```

### Adding MCP Servers

MCP (Model Context Protocol) servers extend your agent's capabilities. Add them via the config editor at `/hm/app/config`:

```yaml
mcp:
  servers:
    fetch:
      command: uvx
      args: ["mcp-server-fetch"]
    filesystem:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/opt/data/workspace"]
```

`uvx` and `npx` are pre-installed in the image.

### Persistence Details

When `HF_TOKEN` is set:

*   **On boot**, the Space downloads the latest snapshot from your private HF Dataset and restores it into `/opt/data/`.
*   **Every `SYNC_INTERVAL` seconds** (default 600), it detects state changes and uploads a new snapshot.
*   **On graceful shutdown** (SIGTERM), it does one final sync before exit.

What gets backed up: chat sessions, agent memory, workspace files, profiles, skills, cron jobs, Hermes config. The dataset is private to your HF account.

### Architecture

Single port (7861) Node.js router fronts multiple backends:

```
HF Space port 7861
        │
        ▼
   health-server.js  (router + auth + status page)
        │
        ├─► /                  → Hermes WebUI         (127.0.0.1:8787)
        ├─► /hm                → HuggingMes status    (in-process)
        ├─► /hm/app/*          → Hermes dashboard     (127.0.0.1:9119)  [SPA-rewritten]
        ├─► /v1/*              → Hermes gateway API   (127.0.0.1:8642)  [bearer auth]
        ├─► /telegram          → Telegram webhook     (127.0.0.1:8765)
        └─► /health, /status   → in-process JSON
```

`start.sh` boots Hermes Agent's gateway + dashboard + WebUI as subprocesses, then the router on top. `hermes-sync.py` runs the periodic HF Dataset upload loop. Cloudflare and Telegram setup runs once at boot if their respective secrets are set.

### Local Testing

Plain container run (mirrors a public Space):

```shell
git clone https://github.com/22f2001388/hermes.git
cd hermes
cp .env.example .env
# edit .env with GATEWAY_TOKEN and provider API keys (e.g., OPENAI_API_KEY, ANTHROPIC_API_KEY)
docker build -t hermes .
docker run --rm -p 7861:7861 --env-file .env hermes
# open http://localhost:7861
```

### Extended Troubleshooting

| Symptom | Cause / Fix |
|--------|-------------|
| Build fails on `nousresearch/hermes-agent:latest` | Set `HERMES_AGENT_VERSION` to a specific tag and restart |
| Container Running but `/` returns 502 | Hermes WebUI didn't bind. Check Logs tab for `webui.log` output — usually missing/wrong provider API key or LLM config |
| `/v1/*` returns 401 | Need `Authorization: Bearer <GATEWAY_TOKEN>` header |
| `/api/status` 404s in logs | Cosmetic — old browser tab polling. Ignored. |
| Dashboard pages blank or 404 on refresh | Should be fixed by the SPA rewriter in health-server.js. Hard-refresh and unregister service worker if cached: DevTools → Application → Service Workers → Unregister |
| Space sleeps after a few hours | Free tier limitation. Add `CLOUDFLARE_WORKERS_TOKEN` to provision a keep-alive cron worker |
| Telegram bot doesn't respond | HF Spaces blocks `api.telegram.org` egress. Add `CLOUDFLARE_WORKERS_TOKEN` to auto-provision an outbound proxy |
| Two Spaces overwriting each other's backup | Set different `BACKUP_DATASET_NAME` on each |
| Agent responds but cannot answer questions | No LLM provider configured. Add provider API keys and restart, or configure via `/hm/app/config` |

## Credits

A fork combining four open-source projects into one Hugging Face Space:

*   **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** by **[Nous Research](https://nousresearch.com/)** — agent runtime: persistent memory, multi-provider LLM routing, cron, skills.
*   **[Hermes WebUI](https://github.com/nesquena/hermes-webui)** by **[@nesquena](https://github.com/nesquena)** — the chat interface: three-panel layout, SSE streaming, slash commands, profiles, themes, mobile.
*   **[HuggingMes](https://github.com/somratpro/HuggingMes)** by **[@somratpro](https://github.com/somratpro)** — HF Space packaging: Dataset backup engine (`hermes-sync.py`), Cloudflare proxy + keepalive, Telegram integration, gateway auth.
*   **[huggingmes-hermes-webui](https://github.com/F4bC0d3/huggingmes-hermes-webui)** by **[@F4bC0d3](https://github.com/F4bC0d3)** — the integration this fork builds on: single-port Node.js router, unified `GATEWAY_TOKEN` auth, `start.sh` wiring.

**This fork adds** a working Telegram bridge for HF Spaces — Cloudflare-proxy `base_url` re-sync, polling mode for private Spaces, connect/retry hardening in `start.sh` and `cloudflare-proxy-setup.py` — plus expanded deployment docs. If this helps you, star the upstream projects.

## License

MIT — see [`LICENSE`](./LICENSE). Original copyright notices and attributions are preserved in [`NOTICE`](./NOTICE).
