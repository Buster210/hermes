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

One image, N agents. Runs [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) as a Telegram gateway with a Gemini backend — locally (`docker compose`), on Hugging Face Spaces, or on Render. Each agent is selected by name from `agents/<name>/` and differs only by its soul, bot token, and secrets.

## Agents

Each agent lives in `agents/<name>/`:

| File | Purpose |
|---|---|
| `soul.md` | Persona/identity prompt. Copied to `$HERMES_HOME/SOUL.md` at boot. |
| `agent.env` | NON-secret per-agent overrides (`HOST_PORT`, `TELEGRAM_BASE_URL`, `AGENT_PERSONALITY`). Tracked in git. |

`AGENT_NAME` selects the agent (and scopes its persistent state under `/data/<AGENT_NAME>/`). Secrets stay in the repo-root `.env` (local) or platform secrets (cloud) — never in `agent.env`.

### Local host-port registry

The container always serves on `7860`; locally each agent maps it to a unique host port (`HOST_PORT` in its `agent.env`) so several agents can run at once without collision. On HF/Render `HOST_PORT` is ignored (the platform assigns the port). When adding an agent, give it the next free port and record it here:

| Agent | `HOST_PORT` |
|---|---|
| `ritesh` | `7860` |
| `engine` | `7861` |

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `AGENT_NAME` | Cloud only | Selects `agents/<AGENT_NAME>/`. Stable per deployment — changing it orphans state. Local: auto-set by `run.sh`. |
| `TELEGRAM_BOT_TOKEN` | Yes | Telegram bot token (from BotFather). One bot per agent. |
| `GEMINI_API_KEYS` | Yes* | JSON list of Gemini keys, e.g. `["AIza...1","AIza...2"]`. All added to a round-robin pool at boot. |
| `GEMINI_API_KEY` | Yes* | Single-key fallback if `GEMINI_API_KEYS` is unset. |
| `TELEGRAM_ALLOWED_USERS` | Yes | Comma-separated Telegram user IDs allowed to DM the bot. |
| `TELEGRAM_HOME_CHANNEL` | No | Chat ID for cron/notification delivery. |
| `TELEGRAM_BASE_URL` | No | Telegram API base URL (proxy). Defaults to the committed Cloudflare Worker. |
| `TELEGRAM_PROXY_HOST` | No | Optional legacy sed-patch host for `api.telegram.org` (kept alongside `TELEGRAM_BASE_URL`). |
| `AGENT_PERSONALITY` | No | Overrides `display.personality` (default `kawaii`). |
| `HF_TOKEN` | No | Hugging Face token (HF provider / model access). |

\* Provide either `GEMINI_API_KEYS` (preferred, N keys) or `GEMINI_API_KEY` (single).

Gemini key pooling: the pool is **reset and re-seeded from `GEMINI_API_KEYS` on every boot**, so it always reflects the current env exactly. Round-robin is set via `credential_pool_strategies.gemini` in config.

## Local development

```bash
./run.sh ritesh          # build + run the "ritesh" agent
./run.sh ritesh logs     # tail logs
./run.sh ritesh down     # stop
```

`run.sh` exports `AGENT_NAME`, layers `.env` then `agents/<name>/agent.env`, and runs `docker compose -p hermes-<name>`. Per-agent state persists under `./.data/<name>/` (mirrors the cloud `/data/<name>/` layout). Each agent boots fresh on first run — no state is migrated from the old `.hermes/`.

## Deployment

See [HF_DEPLOY.md](./HF_DEPLOY.md) (Hugging Face Spaces) and [RENDER.md](./RENDER.md) (Render). One baked image serves every agent; per-agent config comes from secrets injected at boot.
