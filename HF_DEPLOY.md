# HF Deploy: N Hermes Agents on Hugging Face Spaces

One baked image → N independent HF Space agents. Each agent differs by its soul, Telegram bot, and secrets — injected at boot. Per-agent secrets are read from the **environment** (Hermes has no config keys for tokens/keys/allowlists); only the proxy base URL and personality are written to config.

## Architecture

| Layer | Detail |
|---|---|
| Base image | Single Docker build from this repo. All agents share the same image. |
| Per-agent diff | `AGENT_NAME` selects `agents/<AGENT_NAME>/soul.md`. Space secrets inject token, allowlist, and keys at boot. |
| Storage | HF persistent storage (`/data`). Each agent scopes under `/data/<AGENT_NAME>/`. |
| Respawn | `entrypoint.sh` auto-restarts the gateway on crash. |

## Environment variables (Space secrets)

| Variable | Required | Description |
|---|---|---|
| `AGENT_NAME` | Yes | Matches `agents/<AGENT_NAME>/soul.md`. Stable per Space — never change after first deploy (it scopes `/data/<AGENT_NAME>/`; changing it orphans all state). |
| `TELEGRAM_BOT_TOKEN` | Yes | Unique Telegram bot token (one per agent, from BotFather). |
| `TELEGRAM_ALLOWED_USERS` | Yes | Comma-separated Telegram user IDs allowed to DM the bot. |
| `GEMINI_API_KEYS` | Yes* | JSON list of Gemini keys, e.g. `["AIza...1","AIza...2"]`. Reset + re-seeded into a round-robin pool every boot. |
| `GEMINI_API_KEY` | Yes* | Single-key fallback if `GEMINI_API_KEYS` is unset. |
| `TELEGRAM_HOME_CHANNEL` | No | Chat ID for cron/notification delivery. |
| `TELEGRAM_BASE_URL` | No | Telegram API proxy base URL (HF blocks `api.telegram.org`). Defaults to the committed Cloudflare Worker. |
| `AGENT_PERSONALITY` | No | Override `display.personality` (default `kawaii`). |
| `HF_TOKEN` | No | Hugging Face token (for model access). |

\* Provide either `GEMINI_API_KEYS` (preferred) or `GEMINI_API_KEY`.

## Deploy agent N

1. **Create the soul:** add `agents/<AGENT_NAME>/soul.md` (persona) and optional `agents/<AGENT_NAME>/agent.env` (non-secret overrides) in this repo.

2. **Build & push to HF:**
   ```bash
   git add -A
   git commit -m "feat: add <AGENT_NAME> agent"
   git push
   ```

3. **Create a new HF Space** from this repo (`sdk: docker`).

4. **Set Space secrets** — every required variable from the table above.

5. **Enable persistent storage** in Space settings (`/data`).

6. **Deploy.** The Space builds the image and boots the agent.

## Important notes

- **Stable AGENT_NAME:** never change it for an existing Space. State lives at `/data/<AGENT_NAME>/`; a rename orphans sessions, memories, and the credential pool.
- **Gemini pool is env-driven:** keys are reset and re-added from `GEMINI_API_KEYS` on every boot, so editing the secret + restarting the Space updates the pool exactly. No stale keys accumulate.
- **Tokens/allowlists are env-only:** Hermes reads `TELEGRAM_BOT_TOKEN` / `TELEGRAM_ALLOWED_USERS` / `TELEGRAM_HOME_CHANNEL` from the environment — they are NOT written via `hermes config set`.
- **Telegram proxy:** `TELEGRAM_BASE_URL` is set into `gateway.platforms.telegram.extra.base_url`; on HF/Render its host is also sed-patched into Hermes' source to catch the IP-fallback path that bypasses `base_url`.
- **Token rotation:** rotate via BotFather, update the Space secret, restart the Space.
- **Propagation:** soul/base-config changes require a rebuild+redeploy. Image-level changes are shared by all agents.
- **Respawn on crash:** the entrypoint loops forever, restarting the gateway on any non-zero exit.
