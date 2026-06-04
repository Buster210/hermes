#!/usr/bin/env python3
from __future__ import annotations

"""Create/reuse Cloudflare Workers for Telegram proxy + keep-awake. Vendored from HuggingMes."""

import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_BASE = "https://api.cloudflare.com/client/v4"
ENV_FILE = Path("/tmp/hermes-cloudflare-proxy.env")
DEFAULT_ALLOWED = [
    # Messaging & social — primary use-case for Cloudflare proxy on HF Spaces
    # (geo-restrictions on Telegram, Discord, WhatsApp, etc.)
    "api.telegram.org",
    "discord.com",
    "discordapp.com",
    "gateway.discord.gg",
    "status.discord.com",
    "slack.com",
    "api.slack.com",
    "web.whatsapp.com",
    # Social — confirmed/likely blocked by HF firewall
    "graph.facebook.com",
    "graph.instagram.com",
    "api.twitter.com",
    "api.x.com",
    # Google
    "googleapis.com",
    "google.com",
    "googleusercontent.com",
    "gstatic.com",
    # Email HTTP APIs (SMTP ports are blocked)
    "api.resend.com",
    "api.sendgrid.com",
    # NOTE: AI-provider domains (api.openai.com, api.anthropic.com, etc.) are
    # intentionally NOT included here. Proxying AI calls routes API keys through
    # the Cloudflare Worker without explicit opt-in. Users who need AI API calls
    # proxied can add specific domains via CLOUDFLARE_PROXY_DOMAINS env var.
]


def cf_request(method: str, path: str, token: str, body: bytes | None = None, content_type: str = "application/json"):
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=body,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": content_type},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not payload.get("success"):
        errors = payload.get("errors") or [{"message": "Unknown Cloudflare API error"}]
        raise RuntimeError(errors[0].get("message", "Unknown Cloudflare API error"))
    return payload["result"]


def slugify(value: str) -> str:
    cleaned = re.sub(r"[^a-z0-9-]+", "-", value.lower()).strip("-")
    cleaned = re.sub(r"-{2,}", "-", cleaned)
    return (cleaned or "hermes-proxy")[:63].rstrip("-")


def derive_worker_name() -> str:
    explicit = os.environ.get("CLOUDFLARE_WORKER_NAME", "").strip()
    if explicit:
        return slugify(explicit)
    space_host = os.environ.get("SPACE_HOST", "").strip()
    if space_host:
        return slugify(f"{space_host.replace('.hf.space', '')}-proxy")
    return "hermes-proxy"


def render_worker(secret_value: str, allowed_targets: list[str], allow_proxy_all: bool) -> str:
    return f"""addEventListener("fetch", (event) => {{
  event.respondWith(handleRequest(event.request));
}});

const PROXY_SHARED_SECRET = {json.dumps(secret_value)};
const ALLOW_PROXY_ALL = {"true" if allow_proxy_all else "false"};
const ALLOWED_TARGETS = {json.dumps(allowed_targets)};

function isAllowedHost(hostname) {{
  const normalized = String(hostname || "").trim().toLowerCase();
  if (!normalized) return false;
  if (ALLOW_PROXY_ALL) return true;
  return ALLOWED_TARGETS.some((domain) => normalized === domain || normalized.endsWith(`.${{domain}}`));
}}

async function handleRequest(request) {{
  const url = new URL(request.url);
  const queryTarget = url.searchParams.get("proxy_target");
  const targetHost = request.headers.get("x-target-host") || queryTarget;

  if (PROXY_SHARED_SECRET) {{
    const providedSecret = request.headers.get("x-proxy-key") || url.searchParams.get("proxy_key") || "";
    const telegramStylePath = url.pathname.startsWith("/bot") || url.pathname.startsWith("/file/bot");
    if (providedSecret !== PROXY_SHARED_SECRET && !(telegramStylePath && !targetHost)) {{
      return new Response("Unauthorized: Invalid proxy key", {{ status: 401 }});
    }}
  }}

  let targetBase = "";
  if (targetHost) {{
    if (!isAllowedHost(targetHost)) {{
      return new Response(`Forbidden: Host ${{targetHost}} is not allowed.`, {{ status: 403 }});
    }}
    targetBase = `https://${{targetHost}}`;
  }} else if (url.pathname.startsWith("/bot") || url.pathname.startsWith("/file/bot")) {{
    targetBase = "https://api.telegram.org";
  }} else {{
    return new Response("Invalid request: No target host provided.", {{ status: 400 }});
  }}

  const cleanSearch = new URLSearchParams(url.search);
  cleanSearch.delete("proxy_target");
  cleanSearch.delete("proxy_key");
  const searchStr = cleanSearch.toString();
  const targetUrl = targetBase + url.pathname + (searchStr ? `?${{searchStr}}` : "");

  const headers = new Headers(request.headers);
  for (const header of ["cf-connecting-ip", "cf-ray", "cf-visitor", "host", "x-real-ip", "x-target-host", "x-proxy-key"]) {{
    headers.delete(header);
  }}

  try {{
    return await fetch(new Request(targetUrl, {{
      method: request.method,
      headers,
      body: request.body,
      redirect: "follow",
    }}));
  }} catch (error) {{
    return new Response(`Proxy Error: ${{error.message}}`, {{ status: 502 }});
  }}
}}
"""


def write_env(proxy_url: str, proxy_secret: str) -> None:
    ENV_FILE.write_text(
        f'export CLOUDFLARE_PROXY_URL="{proxy_url}"\nexport CLOUDFLARE_PROXY_SECRET="{proxy_secret}"\n',
        encoding="utf-8",
    )
    ENV_FILE.chmod(0o600)


def resolve_account_and_subdomain(api_token: str) -> tuple[str, str]:
    account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
    if not account_id:
        accounts = cf_request("GET", "/accounts", api_token)
        if not accounts:
            raise RuntimeError("No Cloudflare account is available for this token.")
        account_id = accounts[0]["id"]

    subdomain_info = cf_request("GET", f"/accounts/{account_id}/workers/subdomain", api_token)
    subdomain = (subdomain_info or {}).get("subdomain", "").strip()
    if not subdomain:
        raise RuntimeError("Cloudflare Workers subdomain is not configured. Enable workers.dev first.")
    return account_id, subdomain


def _is_telegram_response(body: str) -> bool:
    """Telegram (proxied) answers JSON like {"ok":false,...} even for bad tokens.
    A JSON body means the /bot route reaches api.telegram.org through the worker."""
    return body.lstrip().startswith("{") and '"ok"' in body


def _bot_probe_url(proxy_url: str) -> str:
    return f"{proxy_url.rstrip('/')}/bot0:probe/getMe"


def _probe_live(probe_url: str) -> bool:
    """One probe of the worker's /bot route — the exact path Telegram uses.
    True iff it proxies through to api.telegram.org (JSON response) rather than
    serving Cloudflare's "nothing here yet" propagation placeholder.

    Probing the root is not enough: the worker's root auth-gate (401) goes live
    before the /bot route finishes propagating across edges, so a root probe
    false-positives and the gateway's first getMe still hits the placeholder.
    getMe with a dummy token returns a 401/404 JSON body — the readiness signal.

    A browser User-Agent is mandatory: Cloudflare's bot firewall 403s the default
    Python-urllib UA ("error code: 1010"), which never looks like Telegram JSON."""
    probe = urllib.request.Request(probe_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(probe, timeout=10) as resp:
            return _is_telegram_response(resp.read(2048).decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        # Telegram rejects the dummy token with a JSON 401/404 — still proves the
        # route is live. The CF placeholder comes back as an HTML 404 instead.
        body = exc.read(2048).decode("utf-8", "replace") if exc.fp else ""
        return _is_telegram_response(body)
    except Exception:
        return False


def wait_until_live(proxy_url: str, timeout: int = 300, interval: int = 3, required_streak: int = 4) -> bool:
    """Block until the worker's /bot route is *consistently* live, then return
    True; return False on timeout.

    Requires `required_streak` consecutive live probes, not one: workers.dev
    propagation is non-monotonic, so a fresh route can answer live for a single
    request and then fall back to the placeholder seconds later. Returning on the
    first success releases the gateway too early and it races the route back to a
    placeholder → InvalidToken. A streak means the route is solidly propagated to
    this container's edge (the same edge the gateway will use) before we proceed.

    This call is the only thing gating gateway launch (start.sh runs us, then
    starts the gateway), so the timeout is generous — correctness beats boot
    speed, and an already-live worker confirms its streak in seconds."""
    probe_url = _bot_probe_url(proxy_url)
    deadline = time.monotonic() + timeout
    streak = 0
    while time.monotonic() < deadline:
        if _probe_live(probe_url):
            streak += 1
            if streak >= required_streak:
                return True
        else:
            streak = 0
        time.sleep(interval)
    return False


def main() -> int:
    existing_url = os.environ.get("CLOUDFLARE_PROXY_URL", "").strip()
    existing_secret = os.environ.get("CLOUDFLARE_PROXY_SECRET", "").strip()
    api_token = os.environ.get("CLOUDFLARE_WORKERS_TOKEN", "").strip()

    if existing_url:
        write_env(existing_url, existing_secret)

    if not api_token:
        return 0

    try:
        account_id, subdomain = resolve_account_and_subdomain(api_token)

        if not existing_url:
            worker_name = derive_worker_name()
            proxy_url = f"https://{worker_name}.{subdomain}.workers.dev"

            # Reuse an already-deployed worker instead of redeploying: a
            # PUT/subdomain redeploy resets workers.dev propagation and forces the
            # gateway to race a cold route on every boot. A single live probe is
            # enough to decide "don't redeploy" — it is NOT enough to release the
            # gateway (the route can still flap back to the placeholder), so reuse
            # skips only the deploy API calls and still falls through to the
            # sustained-liveness gate below. Telegram /bot paths bypass the proxy
            # secret in the worker, so reusing without the secret is fine.
            if _probe_live(_bot_probe_url(proxy_url)):
                write_env(proxy_url, existing_secret)
                print(f"Cloudflare worker exists, reusing (no redeploy): {proxy_url}")
            else:
                allowed_raw = os.environ.get("CLOUDFLARE_PROXY_DOMAINS", "").strip()
                allow_proxy_all = allowed_raw == "*"
                extra = [] if allow_proxy_all else [v.strip() for v in allowed_raw.split(",") if v.strip()]
                allowed = list(dict.fromkeys(DEFAULT_ALLOWED + extra))
                proxy_secret = existing_secret or secrets.token_urlsafe(24)

                cf_request(
                    "PUT",
                    f"/accounts/{account_id}/workers/scripts/{worker_name}",
                    api_token,
                    body=render_worker(proxy_secret, allowed, allow_proxy_all).encode("utf-8"),
                    content_type="application/javascript",
                )
                cf_request(
                    "POST",
                    f"/accounts/{account_id}/workers/scripts/{worker_name}/subdomain",
                    api_token,
                    body=json.dumps({"enabled": True, "previews_enabled": True}).encode("utf-8"),
                )
                write_env(proxy_url, proxy_secret)

            # Single gate for both paths: block until the /bot route is
            # CONSISTENTLY live (sustained streak). Releasing the gateway on a
            # transient success lets its first Telegram call hit Cloudflare's
            # placeholder 404 → InvalidToken.
            if wait_until_live(proxy_url):
                print(f"Cloudflare worker live: {proxy_url}")
            else:
                print(f"Cloudflare worker not live yet after wait: {proxy_url}", file=sys.stderr)

        return 0
    except Exception as exc:
        print(f"Cloudflare proxy setup failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
