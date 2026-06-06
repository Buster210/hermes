"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const net = require("net");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 7861);
const GATEWAY_PORT = Number(process.env.API_SERVER_PORT || 8642);
const DASHBOARD_PORT = Number(process.env.DASHBOARD_PORT || 9119);
const TELEGRAM_WEBHOOK_PORT = Number(process.env.TELEGRAM_WEBHOOK_PORT || 8765);
const WEBUI_PORT = Number(process.env.HERMES_WEBUI_PORT || 8787);
const GATEWAY_HOST = "127.0.0.1";
const startTime = Date.now();
const API_SERVER_KEY = process.env.API_SERVER_KEY || "";
const WEBUI_HAS_PASSWORD = !!(process.env.HERMES_WEBUI_PASSWORD || "").trim(); // WebUI self-gates exec paths when its own auth is on, so defer for single-login; when off, router must gate (fail-closed) to preserve df307c7/09ab5f0.
const HM_PREFIX = "/hm";

const HMD_PREFIX = "/hmd";
const LOGIN_PATH = "/hm/login";
const SESSION_COOKIE = "hermes_session";
const PRIMARY_UI = (process.env.PRIMARY_UI || "webui").toLowerCase();

const SYNC_STATUS_FILE = "/tmp/hermes-sync-status.json";
const CLOUDFLARE_KEEPALIVE_STATUS_FILE =
  "/tmp/hermes-cloudflare-keepalive-status.json";

// ── Private Space redirect support ──
const SPACE_ID = (process.env.SPACE_ID || "").trim();
function deriveHfSpaceUrl() {
  if (SPACE_ID) return `https://huggingface.co/spaces/${SPACE_ID}`;
  const host = (process.env.SPACE_HOST || "").replace(/\.hf\.space$/i, "");
  const author = (process.env.SPACE_AUTHOR_NAME || "").trim().toLowerCase();
  if (author && host.toLowerCase().startsWith(author + "-")) {
    const spaceName = host.slice(author.length + 1);
    return `https://huggingface.co/spaces/${process.env.SPACE_AUTHOR_NAME}/${spaceName}`;
  }
  return "";
}
const HF_SPACE_URL = deriveHfSpaceUrl();

// Privacy detection priority:
//   1. SPACE_PRIVACY env var ("public"/"private") — explicit override, skip API call
//   2. HF API auto-detect with retry
//   3. Fail-secure: treat as private if SPACE_ID set
const _spacPrivacyEnv = (process.env.SPACE_PRIVACY || "").trim().toLowerCase();
let SPACE_IS_PRIVATE;
let _privacyDetectionDone = false;
let _privacyDetectionResolve;
const privacyDetectionReady = new Promise((res) => { _privacyDetectionResolve = res; });

if (_spacPrivacyEnv === "public") {
  SPACE_IS_PRIVATE = false;
  _privacyDetectionDone = true;
  console.log("[health-server] Space privacy: public (SPACE_PRIVACY env override)");
  _privacyDetectionResolve();
} else if (_spacPrivacyEnv === "private") {
  SPACE_IS_PRIVATE = true;
  _privacyDetectionDone = true;
  console.log("[health-server] Space privacy: private (SPACE_PRIVACY env override)");
  _privacyDetectionResolve();
} else {
  // Fail-secure default until API call resolves
  SPACE_IS_PRIVATE = !!SPACE_ID;
}

async function detectSpacePrivacy() {
  if (_spacPrivacyEnv === "public" || _spacPrivacyEnv === "private") return;
  if (!SPACE_ID) {
    SPACE_IS_PRIVATE = false;
    _privacyDetectionDone = true;
    _privacyDetectionResolve();
    return;
  }
  const token = (process.env.HF_TOKEN || "").trim();
  const reqOptions = {
    hostname: "huggingface.co",
    path: `/api/spaces/${SPACE_ID}`,
    method: "GET",
    headers: Object.assign(
      { "User-Agent": "Hermes/health-server" },
      token ? { Authorization: `Bearer ${token}` } : {}
    ),
  };
  const MAX_ATTEMPTS = 5;
  let detected = false;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const result = await new Promise((resolve) => {
        const r = https.request(reqOptions, (apiRes) => {
          let body = "";
          apiRes.on("data", (chunk) => { body += chunk; });
          apiRes.on("end", () => {
            try {
              if (apiRes.statusCode === 200) {
                SPACE_IS_PRIVATE = JSON.parse(body).private === true;
                resolve({ ok: true });
              } else if (apiRes.statusCode === 401 || apiRes.statusCode === 403) {
                SPACE_IS_PRIVATE = true;
                resolve({ ok: true });
              } else {
                resolve({ ok: false });
              }
            } catch { resolve({ ok: false }); }
          });
        });
        r.on("error", () => resolve({ ok: false }));
        r.setTimeout(8000, () => { r.destroy(); resolve({ ok: false }); });
        r.end();
      });
      console.log(`[health-server] Privacy detection attempt ${attempt}/${MAX_ATTEMPTS}: ok=${result.ok}`);
      if (result.ok) { detected = true; break; }
    } catch {}
    const delay = Math.min(2000 * attempt, 10000);
    if (attempt < MAX_ATTEMPTS) await new Promise((r) => setTimeout(r, delay));
  }
  if (!detected) {
    console.warn(`[health-server] Privacy detection failed after ${MAX_ATTEMPTS} attempts — defaulting to ${SPACE_IS_PRIVATE ? "private" : "public"}. TIP: Set SPACE_PRIVACY=public in Space secrets to skip API detection.`);
  } else {
    console.log(`[health-server] Space privacy detected: ${SPACE_IS_PRIVATE ? "private" : "public"}`);
  }
  _privacyDetectionDone = true;
  _privacyDetectionResolve();
}

if (_spacPrivacyEnv !== "public" && _spacPrivacyEnv !== "private") {
  detectSpacePrivacy();
  setInterval(detectSpacePrivacy, 5 * 60 * 1000);
}

function canConnect(port, host = GATEWAY_HOST, timeoutMs = 600) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ port, host });
    const done = (ok) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}

function readJson(path, fallback = null) {
  try {
    if (fs.existsSync(path)) return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch {}
  return fallback;
}

function timingSafeEqualString(left, right) {
  if (!left || !right) return false;
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function expectedSessionValue() {
  if (!API_SERVER_KEY) return "";
  return crypto
    .createHmac("sha256", API_SERVER_KEY)
    .update("hermes-session-v1")
    .digest("hex");
}

function parseCookies(req) {
  const header = req.headers.cookie || "";
  const cookies = {};
  for (const item of header.split(";")) {
    const sep = item.indexOf("=");
    if (sep < 0) continue;
    const name = item.slice(0, sep).trim();
    const value = item.slice(sep + 1).trim();
    if (!name) continue;
    try {
      cookies[name] = decodeURIComponent(value);
    } catch {
      cookies[name] = value;
    }
  }
  return cookies;
}

function isHttpsRequest(req) {
  return req.headers["x-forwarded-proto"] === "https";
}

function buildSessionCookie(req) {
  const secure = isHttpsRequest(req) ? "; Secure" : "";
  return `${SESSION_COOKIE}=${encodeURIComponent(expectedSessionValue())}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400${secure}`;
}

function getBearerToken(req) {
  const value = req.headers.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match ? match[1] : "";
}

function isAuthorized(req) {
  if (!API_SERVER_KEY) return true;
  return (
    timingSafeEqualString(getBearerToken(req), API_SERVER_KEY) ||
    timingSafeEqualString(
      parseCookies(req)[SESSION_COOKIE],
      expectedSessionValue(),
    )
  );
}

function sanitizeNext(value, fallback = "/") {
  if (!value || typeof value !== "string") return fallback;
  if (!value.startsWith("/") || value.startsWith("//")) return fallback;
  return value;
}

function loginUrl(nextPath) {
  return `${LOGIN_PATH}?next=${encodeURIComponent(sanitizeNext(nextPath))}`;
}

function wantsHtml(req) {
  const accept = String(req.headers.accept || "");
  return accept.includes("text/html");
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderPrivateRedirect(targetUrl) {
  const safeUrl = escapeHtml(targetUrl);
  return `<!doctype html><html lang="en"><head>
  <meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
  <meta http-equiv="refresh" content="3;url=${safeUrl}"/>
  <title>Hermes — Private Space</title>
  <style>
    :root{color-scheme:dark}
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
         font-family:Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;
         background:#08080f;color:#f6f4ff;text-align:center;padding:24px}
    .card{border:1px solid #26243a;background:#12111b;border-radius:14px;padding:36px 32px;max-width:440px}
    h1{margin:0 0 12px;font-size:1.5rem}
    p{color:#b8b3d7;line-height:1.6;margin:0 0 24px}
    .btn{display:inline-flex;align-items:center;justify-content:center;
         background:#fff;color:#000;font-weight:850;font-size:.95rem;
         border-radius:8px;padding:12px 28px;text-decoration:none;transition:opacity .15s}
    .btn:hover{opacity:.85}
    .sub{color:#7f7a9e;font-size:.78rem;margin-top:16px}
  </style></head><body>
  <div class="card">
    <h1>🔒 Private Space</h1>
    <p>This HuggingFace Space is private. You need to be logged in to <strong>huggingface.co</strong> to access it.<br><br>Redirecting you now&hellip;</p>
    <a class="btn" href="${safeUrl}">Open on Hugging Face →</a>
    <div class="sub">Redirecting in 3 seconds&hellip;</div>
  </div>
  <script>
    // Only auto-redirect when NOT inside an iframe — navigating an iframe to
    // huggingface.co is blocked by X-Frame-Options and causes "refused to connect".
    const _inFrame = (() => { try { return window.top !== window.self; } catch { return true; } })();
    if (!_inFrame) {
      setTimeout(() => { window.location.replace(${JSON.stringify(targetUrl)}); }, 100);
    }
  </script>
</body></html>`;
}

function isDashboardAssetPath(path) {
  return (
    path.startsWith("/assets/") ||
    path.startsWith("/ds-assets/") ||
    path.startsWith("/dashboard-plugins/") ||
    path.startsWith("/api/") ||
    path === "/favicon.ico" ||
    /\.[a-z0-9]{1,6}$/i.test(path)
  );
}

function readRequestBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error("Request body is too large."));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function renderLoginPage(nextPath, errorMessage = "") {
  const safeNext = sanitizeNext(nextPath, "/");
  const errorHtml = errorMessage
    ? `<div class="error">${escapeHtml(errorMessage)}</div>`
    : "";
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hermes WebUI — Login</title>
  <style>
    :root { color-scheme: dark; --bg:#10141f; --panel:#171d2b; --line:#293246; --text:#f4f7fb; --muted:#9aa7bd; --bad:#ef4444; --accent:#38bdf8; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; display:grid; place-items:center; font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); padding:20px; }
    main { width:min(440px, 100%); border:1px solid var(--line); background:var(--panel); border-radius:8px; padding:28px; }
    h1 { margin:0 0 8px; font-size:1.55rem; }
    p { margin:0 0 22px; color:var(--muted); line-height:1.5; }
    label { display:block; color:var(--muted); font-size:.82rem; margin-bottom:8px; }
    input { width:100%; min-height:46px; border:1px solid var(--line); border-radius:7px; background:#0b0f18; color:var(--text); padding:0 12px; font:inherit; }
    button { width:100%; min-height:44px; margin-top:16px; border:0; border-radius:7px; color:#07111f; background:var(--accent); font:inherit; font-weight:750; cursor:pointer; }
    .error { border:1px solid rgba(239,68,68,.4); background:rgba(239,68,68,.1); color:#fecaca; border-radius:7px; padding:10px 12px; margin-bottom:16px; }
  </style>
</head>
<body>
  <main>
    <h1>Hermes Admin</h1>
    <p>Enter the <code>GATEWAY_TOKEN</code> from your Space secrets to access the status dashboard.<br>For the Hermes chat UI, go to <a href="/" style="color:var(--accent)">/</a>.</p>
    ${errorHtml}
    <form method="post" action="${LOGIN_PATH}">
      <input type="hidden" name="next" value="${escapeHtml(safeNext)}" />
      <label for="token">GATEWAY_TOKEN</label>
      <input id="token" name="token" type="password" autocomplete="current-password" autofocus required />
      <button type="submit">Continue</button>
    </form>
  </main>
</body>
</html>`;
}

async function handleLogin(req, res, parsed) {
  const nextPath = sanitizeNext(parsed.searchParams.get("next") || "/", "/");

  if (!API_SERVER_KEY) {
    redirect(res, nextPath);
    return;
  }

  if (req.method === "GET") {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(renderLoginPage(nextPath));
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405, { allow: "GET, POST" });
    res.end("Method not allowed");
    return;
  }

  try {
    const body = await readRequestBody(req);
    const params = new URLSearchParams(body);
    const submittedToken = params.get("token") || "";
    const submittedNext = sanitizeNext(params.get("next") || nextPath, "/");

    if (!timingSafeEqualString(submittedToken, API_SERVER_KEY)) {
      res.writeHead(401, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
      });
      res.end(
        renderLoginPage(
          submittedNext,
          "That token did not match GATEWAY_TOKEN.",
        ),
      );
      return;
    }

    res.writeHead(302, {
      location: submittedNext,
      "set-cookie": buildSessionCookie(req),
      "cache-control": "no-store",
    });
    res.end();
  } catch (error) {
    res.writeHead(400, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(error.message || "Invalid login request.");
  }
}

function requireAuth(req, res) {
  if (isAuthorized(req)) return true;
  const parsed = new URL(req.url, "http://localhost");
  redirect(res, loginUrl(`${parsed.pathname}${parsed.search}`));
  return false;
}

// WebUI exec/terminal surface — RCE-class, gated at the router before the
// unauthenticated WebUI proxy fallback (HTTP and WebSocket upgrade).
const WEBUI_EXEC_PATHS = new Set([
  "/api/terminal/start",
  "/api/terminal/input",
  "/api/terminal/resize",
  "/api/terminal/close",
  "/api/terminal/output",
  "/api/commands/exec",
]);
function isWebuiExecPath(path) {
  const normalized = path.length > 1 ? path.replace(/\/+$/, "") : path;
  return WEBUI_EXEC_PATHS.has(normalized);
}

function proxyRequest(
  req,
  res,
  targetPort,
  rewritePath = (path) => path,
  headerOverrides = {},
) {
  const parsed = new URL(req.url, "http://localhost");
  const targetPath = rewritePath(parsed.pathname) + parsed.search;
  const headers = {
    ...req.headers,
    ...headerOverrides,
    host: `${GATEWAY_HOST}:${targetPort}`,
    "x-forwarded-host": req.headers.host || "",
    "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",
  };

  const proxy = http.request(
    {
      hostname: GATEWAY_HOST,
      port: targetPort,
      method: req.method,
      path: targetPath,
      headers,
    },
    (upstream) => {
      res.writeHead(upstream.statusCode || 502, upstream.headers);
      upstream.pipe(res);
    },
  );

  proxy.on("error", (error) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
  });

  req.pipe(proxy);
}

function redirect(res, location, statusCode = 302) {
  res.writeHead(statusCode, { location });
  res.end();
}

function proxyDashboard(req, res) {
  const parsed = new URL(req.url, "http://localhost");
  const inner = parsed.pathname.replace(`${HM_PREFIX}/app`, "") || "/";

  const isAssetLike =
    inner.startsWith("/assets/") ||
    inner.startsWith("/api/") ||
    inner.startsWith("/dashboard-plugins/") ||
    inner.startsWith("/ds-assets/") ||
    /\.[a-z0-9]{1,6}$/i.test(inner);

  const targetPath =
    (isAssetLike || inner === "/" ? inner : "/") + parsed.search;

  const headers = {
    ...req.headers,
    host: `${GATEWAY_HOST}:${DASHBOARD_PORT}`,
    "x-forwarded-host": req.headers.host || "",
    "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",
    
    "accept-encoding": "identity",
  };

  const upstream = http.request(
    {
      hostname: GATEWAY_HOST,
      port: DASHBOARD_PORT,
      method: req.method,
      path: targetPath,
      headers,
    },
    (upRes) => {
      const contentType = String(upRes.headers["content-type"] || "");
      const shouldRewrite =
        contentType.includes("text/html") ||
        contentType.includes("application/xhtml");

      if (!shouldRewrite) {
        res.writeHead(upRes.statusCode || 502, upRes.headers);
        upRes.pipe(res);
        return;
      }

      const chunks = [];
      upRes.on("data", (chunk) => chunks.push(chunk));
      upRes.on("end", () => {
        let body = Buffer.concat(chunks).toString("utf8");

        body = body.replace(
          /window\.__HERMES_BASE_PATH__\s*=\s*"[^"]*"/g,
          `window.__HERMES_BASE_PATH__="${HM_PREFIX}/app"`,
        );

        const prefix = `${HM_PREFIX}/app`;
        body = body.replace(
          /\b(src|href)="\/(?!\/|http)([^"]*)"/g,
          (match, attr, rest) => {
            if (
              ("/" + rest).startsWith(prefix + "/") ||
              "/" + rest === prefix
            ) {
              return match;
            }
            return `${attr}="${prefix}/${rest}"`;
          },
        );

        const buf = Buffer.from(body, "utf8");
        const outHeaders = { ...upRes.headers };
        delete outHeaders["content-length"];
        delete outHeaders["transfer-encoding"];
        delete outHeaders["content-encoding"];
        outHeaders["content-length"] = String(buf.length);

        res.writeHead(upRes.statusCode || 502, outHeaders);
        res.end(buf);
      });
      upRes.on("error", () => {
        try {
          res.writeHead(502);
          res.end();
        } catch {}
      });
    },
  );

  upstream.on("error", (error) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
  });

  req.pipe(upstream);
}

function formatUptime(ms) {
  const total = Math.floor(ms / 1000);
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days}d ${hours}h ${minutes}m`;
  if (hours) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

async function statusPayload() {
  const gateway = await canConnect(GATEWAY_PORT);
  const dashboard = await canConnect(DASHBOARD_PORT);
  const webui = await canConnect(WEBUI_PORT);
  const telegramWebhook =
    !!process.env.TELEGRAM_WEBHOOK_URL &&
    (await canConnect(TELEGRAM_WEBHOOK_PORT));
  const sync = readJson(
    SYNC_STATUS_FILE,
    process.env.HF_TOKEN
      ? { status: "configured", message: "Backup enabled; waiting for first sync." }
      : { status: "disabled", message: "HF_TOKEN is not configured." },
  );

  return {
    ok: gateway && webui,
    uptime: formatUptime(Date.now() - startTime),
    startedAt: new Date(startTime).toISOString(),
    gateway,
    dashboard,
    webui,
    authConfigured: !!API_SERVER_KEY,
    primaryUi: PRIMARY_UI,
    ports: {
      public: PORT,
      gateway: GATEWAY_PORT,
      dashboard: DASHBOARD_PORT,
      webui: WEBUI_PORT,
      telegramWebhook: TELEGRAM_WEBHOOK_PORT,
    },
    telegram: {
      configured: !!process.env.TELEGRAM_BOT_TOKEN,
      webhook: !!process.env.TELEGRAM_WEBHOOK_URL,
      webhookUrl: process.env.TELEGRAM_WEBHOOK_URL || "",
      webhookListening: telegramWebhook,
      proxy: process.env.CLOUDFLARE_PROXY_URL || "",
    },
    model:
      process.env.MODEL_FOR_CONFIG ||
      process.env.HERMES_MODEL ||
      process.env.LLM_MODEL ||
      "",
    provider:
      process.env.PROVIDER_FOR_CONFIG ||
      process.env.HERMES_INFERENCE_PROVIDER ||
      "auto",
    backup: sync,
    keepalive: readJson(CLOUDFLARE_KEEPALIVE_STATUS_FILE, null),
  };
}

function toneBadge(label, tone = "neutral") {
  return `<span class="badge ${tone}">${escapeHtml(label)}</span>`;
}

function valueOrUnset(value, fallback = "Not set") {
  return value
    ? escapeHtml(value)
    : `<span class="muted">${escapeHtml(fallback)}</span>`;
}

function renderTile({ title, value, detail = "", tone = "neutral", meta = "" }) {
  return `<article class="tile ${tone}">
    <div class="tile-head">
      <span class="tile-title">${escapeHtml(title)}</span>
      <span class="tile-dot"></span>
    </div>
    <div class="tile-value">${value}</div>
    ${detail ? `<div class="tile-detail">${detail}</div>` : ""}
    ${meta ? `<div class="tile-meta">${meta}</div>` : ""}
  </article>`;
}

function renderTiles(data) {
  const syncStatus = String(data.backup?.status || "unknown");
  const syncTone = ["success", "restored", "synced", "configured"].includes(syncStatus)
    ? "ok"
    : syncStatus === "disabled"
      ? "warn"
      : "neutral";
  const telegramTone = data.telegram.configured
    ? data.telegram.webhookListening || !data.telegram.webhook
      ? "ok"
      : "warn"
    : "warn";
  const keepaliveConfigured = data.keepalive?.configured === true;
  const keepaliveStatus = String(
    data.keepalive?.status ||
      (process.env.CLOUDFLARE_WORKERS_TOKEN ? "pending" : "not configured"),
  );
  const keepAliveTone = keepaliveConfigured
    ? "ok"
    : process.env.CLOUDFLARE_WORKERS_TOKEN
      ? "warn"
      : "neutral";
  const telegramDetail = data.telegram.configured
    ? `${data.telegram.webhook ? "Webhook" : "Polling"}${data.telegram.proxy ? " via CF proxy" : ""}`
    : "Not configured";
  const backupDetail = data.backup?.message
    ? escapeHtml(data.backup.message)
    : "No status yet";
  
  const backupWarning = data.backup?.warning?.message
    ? `<div class="tile-warning">${escapeHtml(data.backup.warning.message)}</div>`
    : "";
  const keepAliveDetail = keepaliveConfigured
    ? `Pinging <code>${escapeHtml(data.keepalive.targetUrl || "/health")}</code>`
    : keepaliveStatus === "error" && data.keepalive?.message
      ? escapeHtml(data.keepalive.message)
      : process.env.CLOUDFLARE_WORKERS_TOKEN
        ? "Worker pending or failed"
        : "Not configured";

  return [
    renderTile({
      title: "WebUI",
      value: toneBadge(data.webui ? "Online" : "Offline", data.webui ? "ok" : "off"),
      detail: data.webui ? `Port ${data.ports.webui}` : "Unreachable",
      tone: data.webui ? "ok" : "off",
    }),
    renderTile({
      title: "Gateway",
      value: toneBadge(data.gateway ? "Online" : "Offline", data.gateway ? "ok" : "off"),
      detail: data.gateway ? `API on port ${data.ports.gateway}` : "Unreachable",
      tone: data.gateway ? "ok" : "off",
      meta: data.authConfigured ? "Protected" : "Unprotected",
    }),
    renderTile({
      title: "Model",
      value: `<code>${valueOrUnset(data.model)}</code>`,
      detail: `Provider: ${valueOrUnset(data.provider || "auto")}`,
      tone: data.model ? "ok" : "warn",
    }),
    renderTile({
      title: "Runtime",
      value: escapeHtml(data.uptime),
      detail: `Port ${data.ports.public}`,
      tone: "neutral",
    }),
    renderTile({
      title: "Telegram",
      value: toneBadge(data.telegram.configured ? "Configured" : "Disabled", telegramTone),
      detail: telegramDetail,
      tone: telegramTone,
    }),
    renderTile({
      title: "Backup",
      value: toneBadge(syncStatus.toUpperCase(), data.backup?.warning ? "warn" : syncTone),
      detail: backupDetail + backupWarning,
      tone: data.backup?.warning ? "warn" : syncTone,
      meta: data.backup?.timestamp
        ? `<span class="local-time" data-iso="${data.backup.timestamp}"></span>`
        : "",
    }),
    renderTile({
      title: "Keep Awake",
      value: toneBadge(
        keepaliveConfigured ? "CF Cron" : keepaliveStatus.toUpperCase(),
        keepAliveTone,
      ),
      detail: keepAliveDetail,
      tone: keepAliveTone,
    }),
  ].join("");
}

function renderStatusPage(data) {
  const tiles = renderTiles(data);

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hermes WebUI</title>
  <style>
    :root { color-scheme: dark; --bg:#08080f; --panel:#12111b; --line:#26243a; --text:#f6f4ff; --muted:#7f7a9e; --soft:#b8b3d7; --good:#22c55e; --warn:#f5c542; --bad:#fb7185; --accent:#6557df; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); font-size:13px; }
    main { width:min(720px, calc(100% - 32px)); margin:0 auto; padding:36px 0 44px; }
    header { text-align:center; margin-bottom:22px; }
    h1 { margin:0; font-size:1.65rem; }
    .subtitle { margin-top:12px; color:var(--muted); font-size:.72rem; text-transform:uppercase; letter-spacing:.14em; font-weight:800; }
    .row { display:flex; gap:10px; margin:24px 0 20px; flex-wrap:wrap; }
    .hero-action { flex:1 1 200px; min-height:46px; display:flex; align-items:center; justify-content:center; border-radius:8px; background:#ffffff; color:#000000; text-decoration:none; font-weight:850; font-size:.98rem; }
    .hero-action.secondary { background:#232234; color:var(--text); border:1px solid var(--line); }
    .hero-action:hover { opacity:.9; }
    .overview { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:10px; margin-bottom:10px; }
    .tile { border:1px solid var(--line); background:var(--panel); border-radius:11px; padding:18px; min-height:124px; display:flex; flex-direction:column; gap:10px; position:relative; }
    .tile.ok { border-color:rgba(34,197,94,.22); }
    .tile.warn { border-color:rgba(245,197,66,.24); }
    .tile.off { border-color:rgba(251,113,133,.28); }
    .tile-head { display:flex; align-items:center; justify-content:space-between; gap:12px; }
    .tile-title { color:var(--muted); font-size:.67rem; letter-spacing:.18em; text-transform:uppercase; font-weight:850; }
    .tile-dot { width:7px; height:7px; border-radius:50%; background:var(--line); }
    .tile.ok .tile-dot { background:var(--good); }
    .tile.warn .tile-dot { background:var(--warn); }
    .tile.off .tile-dot { background:var(--bad); }
    .tile-value { font-size:1.12rem; font-weight:850; overflow-wrap:anywhere; }
    .tile-detail { color:var(--soft); line-height:1.45; font-size:.83rem; }
    .tile-meta { color:var(--muted); line-height:1.4; font-size:.75rem; margin-top:auto; overflow-wrap:anywhere; }
    .tile-warning { color:#fde68a; background:rgba(245,158,11,.08); border:1px solid rgba(245,158,11,.32); border-radius:6px; padding:6px 8px; margin-top:6px; font-size:.78rem; line-height:1.4; }
    code { background:#232234; border:1px solid #34324c; border-radius:6px; padding:2px 6px; color:var(--text); font-size:.9em; }
    .badge { display:inline-flex; align-items:center; border:1px solid var(--line); border-radius:999px; padding:5px 10px; font-size:.72rem; font-weight:850; line-height:1; text-transform:uppercase; }
    .badge.ok { color:var(--good); border-color:rgba(34,197,94,.34); background:rgba(34,197,94,.11); }
    .badge.warn { color:var(--warn); border-color:rgba(245,197,66,.34); background:rgba(245,197,66,.11); }
    .badge.off { color:var(--bad); border-color:rgba(251,113,133,.34); background:rgba(251,113,133,.11); }
    .badge.neutral { color:var(--soft); }
    .muted { color:var(--muted); }
    footer { color:var(--muted); text-align:center; font-size:.74rem; margin-top:18px; }
    @media (max-width: 700px) { .overview { grid-template-columns:1fr; } }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Hermes WebUI</h1>
      <div class="subtitle">Self-hosted Hermes Agent on HF Spaces</div>
    </header>
    <div class="row">
      <a class="hero-action" href="/" target="_blank" rel="noopener">Open Hermes WebUI -&gt;</a>
      <a class="hero-action secondary" href="${HM_PREFIX}/app/" target="_blank" rel="noopener">Open Hermes Dashboard</a>
    </div>
    <section class="overview">
      ${tiles}
    </section>
    <footer>Built on <a href="https://github.com/somratpro/HuggingMes" style="color:var(--accent)">HuggingMes</a> + <a href="https://github.com/nesquena/hermes-webui" style="color:var(--accent)">Hermes WebUI</a></footer>
  </main>
  <script>
    function formatLocalTimes(root) {
      root.querySelectorAll('.local-time').forEach(el => {
        const date = new Date(el.getAttribute('data-iso'));
        if (!isNaN(date)) el.textContent = 'At ' + date.toLocaleTimeString();
      });
    }
    formatLocalTimes(document);

    // Live-poll the tiles fragment so ops status refreshes without a reload.
    // Fragment is first-party, server-escaped HTML; parsed into nodes (no innerHTML sink).
    const overview = document.querySelector('.overview');
    const POLL_MIN_MS = 2000;
    const POLL_MAX_MS = 10000;
    let polling = false;
    async function refreshTiles() {
      if (polling || document.hidden || !overview) return;
      polling = true;
      try {
        // redirect:'manual' so an expired-session 302->login yields ok:false
        // instead of following through and replacing tiles with the login page.
        const res = await fetch('${HM_PREFIX}/tiles', { cache: 'no-store', redirect: 'manual' });
        if (!res.ok) return;
        const parsed = new DOMParser().parseFromString(await res.text(), 'text/html');
        overview.replaceChildren(...parsed.body.childNodes);
        formatLocalTimes(overview);
      } catch {
        // Transient network/auth hiccup — keep last good render, retry next tick.
      } finally {
        polling = false;
      }
    }
    // Jittered 2-10s interval: decorrelates polls across open tabs, fresh delay each tick.
    function scheduleNext() {
      const delay = POLL_MIN_MS + Math.random() * (POLL_MAX_MS - POLL_MIN_MS);
      setTimeout(async () => {
        await refreshTiles();
        scheduleNext();
      }, delay);
    }
    scheduleNext();

    // Sync privacy detection on client side.
    const inEmbeddedApp = (() => { try { return window.top !== window.self; } catch { return true; } })();
    const isDirectHfSpaceHost = /\.hf\.space$/i.test(window.location.hostname);
    const HF_SPACE_URL = ${JSON.stringify(HF_SPACE_URL)};
    let SPACE_IS_PRIVATE = ${JSON.stringify(SPACE_IS_PRIVATE)};

    function syncPrivacy() {
      return fetch('/api/is-private', { cache: 'no-store' })
        .then(r => r.json())
        .then(d => {
          if (d.isPrivate !== SPACE_IS_PRIVATE) {
            SPACE_IS_PRIVATE = d.isPrivate;
          }
          return d.isPrivate;
        })
        .catch(() => SPACE_IS_PRIVATE);
    }

    if (isDirectHfSpaceHost && !inEmbeddedApp) {
      syncPrivacy().then(isPrivate => {
        if (isPrivate) {
          setTimeout(syncPrivacy, 8000);
          setTimeout(syncPrivacy, 16000);
        }
      });
    }
  </script>
</body>
</html>`;
}

const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, "http://localhost");
  const path = parsed.pathname;

  if (path === LOGIN_PATH) {
    await handleLogin(req, res, parsed);
    return;
  }

  if (path === "/health") {
    const data = await statusPayload();
    // Always 200 so the HF Space platform probe keeps the container alive while
    // the gateway warms up or the supervisor respawns it; truthful health is in
    // the body (ok/gateway/webui) and at /status. A 503 here makes HF kill a
    // container the supervisor would have recovered on its own.
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: data.ok,
        gateway: data.gateway,
        webui: data.webui,
        uptime: data.uptime,
      }),
    );
    return;
  }

  if (path === "/status" || path === "/api/status") {
    const data = await statusPayload();
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(data, null, 2));
    return;
  }

  // Lightweight endpoint for client-side privacy fallback.
  // Called by status page JS to correct stale server-rendered SPACE_IS_PRIVATE value.
  // No auth required — not sensitive.
  if (path === "/api/is-private") {
    if (!_privacyDetectionDone) await privacyDetectionReady;
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    return res.end(JSON.stringify({ isPrivate: SPACE_IS_PRIVATE }));
  }

  // Private Space redirect unauth route — external entry point that always redirects.
  if (path === "/hf-redirect" || path === "/hf-redirect/") {
    if (HF_SPACE_URL) {
      res.writeHead(302, { location: HF_SPACE_URL, "cache-control": "no-store" });
      return res.end();
    }
    res.writeHead(404, { "content-type": "text/plain" });
    return res.end("SPACE_ID not configured.");
  }

  // ENV Builder — token-gated helper that generates a .env from a guided form.
  if (path === "/env-builder" || path === "/env-builder/") {
    if (!requireAuth(req, res)) return;
    try {
      const html = fs.readFileSync(
        require("path").join(__dirname, "env-builder.html"),
        "utf8",
      );
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(html);
    } catch {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("env-builder.html not found");
    }
    return;
  }

  if (path === "/env-builder.js") {
    if (!requireAuth(req, res)) return;
    try {
      const js = fs.readFileSync(
        require("path").join(__dirname, "env-builder.js"),
        "utf8",
      );
      res.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
      });
      res.end(js);
    } catch {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("env-builder.js not found");
    }
    return;
  }

  if (path === "/telegram" || path.startsWith("/telegram/")) {
    proxyRequest(req, res, TELEGRAM_WEBHOOK_PORT);
    return;
  }

  if (path === "/v1" || path.startsWith("/v1/")) {
    if (!isAuthorized(req)) {
      if (wantsHtml(req)) {
        redirect(res, loginUrl(`${path}${parsed.search}`));
        return;
      }
      res.writeHead(401, {
        "content-type": "application/json",
        "cache-control": "no-store",
      });
      res.end(
        JSON.stringify({
          error: "unauthorized",
          message: "Use Authorization: Bearer <GATEWAY_TOKEN>.",
        }),
      );
      return;
    }
    const upstreamHeaders =
      getBearerToken(req) || !API_SERVER_KEY
        ? {}
        : { authorization: `Bearer ${API_SERVER_KEY}` };
    proxyRequest(req, res, GATEWAY_PORT, (p) => p, upstreamHeaders);
    return;
  }

  if (path === HM_PREFIX || path === `${HM_PREFIX}/`) {
    if (!requireAuth(req, res)) return;
    const data = await statusPayload();
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(renderStatusPage(data));
    return;
  }

  if (path === HMD_PREFIX || path.startsWith(`${HMD_PREFIX}/`)) {
    proxyRequest(req, res, DASHBOARD_PORT, (p) => p.replace(HMD_PREFIX, "") || "/");
    return;
  }

  if (path === `${HM_PREFIX}/app` || path.startsWith(`${HM_PREFIX}/app/`)) {
    if (!requireAuth(req, res)) return;
    proxyDashboard(req, res);
    return;
  }

  if (path === `${HM_PREFIX}/status`) {
    if (!requireAuth(req, res)) return;
    const data = await statusPayload();
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(data, null, 2));
    return;
  }

  // /hm/tiles — rendered status tiles fragment for the live-poll on the status page.
  if (path === `${HM_PREFIX}/tiles`) {
    if (!requireAuth(req, res)) return;
    const data = await statusPayload();
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(renderTiles(data));
    return;
  }

  if (path === "/dashboard" || path === "/dashboard/") {
    redirect(res, `${HM_PREFIX}${parsed.search}`);
    return;
  }

  const dashboardRootRoutes = new Set([
    "/config",
    "/env",
    "/models",
    "/providers",
    "/profiles",
    "/sessions",
    "/skills",
    "/cron",
    "/analytics",
    "/logs",
    "/plugins",
    "/chat",
    "/docs",
  ]);
  if (dashboardRootRoutes.has(path) || [...dashboardRootRoutes].some((r) => path.startsWith(r + "/"))) {
    redirect(res, `${HM_PREFIX}/app${path}${parsed.search}`);
    return;
  }

  const refererPath = (() => {
    const ref = String(req.headers.referer || "");
    if (!ref) return "";
    try {
      return new URL(ref).pathname;
    } catch {
      return "";
    }
  })();
  const refererIsDashboard = refererPath.startsWith(`${HM_PREFIX}/app`);

  if (refererIsDashboard && !path.startsWith("/webui")) {
    if (!requireAuth(req, res)) return;
    if (isDashboardAssetPath(path)) {
      proxyRequest(req, res, DASHBOARD_PORT);
    } else {
      proxyDashboard(req, res);
    }
    return;
  }

  if (
    /^\/api\/sessions\/[^/]+\/chat\/stream\/?$/.test(path) &&
    !refererIsDashboard
  ) {
    res.writeHead(404, {
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    res.end(
      JSON.stringify({
        error: "not_found",
        message:
          "Legacy enhanced-fork chat stream is not exposed by this Space. Use /v1/chat/completions.",
      }),
    );
    return;
  }

  if (PRIMARY_UI === "dashboard" && path === "/") {
    if (!requireAuth(req, res)) return;
    const data = await statusPayload();
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(renderStatusPage(data));
    return;
  }

  // ── Private Space redirect for HTML root requests ──
  // On a public HF Space, never redirect. On a private Space hit directly via
  // .hf.space (not HF-logged-in, not framed), serve a "private space" page
  // that meta-refreshes to the canonical HF URL but suppresses the redirect
  // inside an iframe (avoids X-Frame-Options: DENY "refused to connect").
  const isHtmlReq = (req.headers.accept || "").includes("text/html");
  const isDirectHfSpaceReq = SPACE_IS_PRIVATE &&
    HF_SPACE_URL &&
    isHtmlReq &&
    typeof req.headers.host === "string" &&
    req.headers.host.endsWith(".hf.space");

  if (isDirectHfSpaceReq && !_privacyDetectionDone) {
    await Promise.race([
      privacyDetectionReady,
      new Promise((r) => setTimeout(r, 1500)),
    ]);
  }

  if (path === "/" && isDirectHfSpaceReq && SPACE_IS_PRIVATE) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(renderPrivateRedirect(HF_SPACE_URL));
  }

  if (isWebuiExecPath(path) && !WEBUI_HAS_PASSWORD) {
    if (!requireAuth(req, res)) return;
  }

  proxyRequest(req, res, WEBUI_PORT);
});

// HF's load balancer holds long-lived streaming responses open; disable Node's
// default socket timeout so long SSE/agent streams aren't dropped, and keep
// keepAliveTimeout above the LB's ~60s idle window.
server.timeout = 0;
server.keepAliveTimeout = 65000;

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Hermes WebUI router listening on 0.0.0.0:${PORT}`);
});

server.on("upgrade", (req, clientSocket, head) => {
  const parsed = new URL(req.url, "http://localhost");
  const path = parsed.pathname;

  // Same router-level gate as the HTTP path: terminal/exec upgrades require
  // auth. No res object here, so reject the socket directly.
  if (isWebuiExecPath(path) && !WEBUI_HAS_PASSWORD && !isAuthorized(req)) {
    try {
      clientSocket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
    } catch {}
    return;
  }

  let targetPort = WEBUI_PORT;
  let targetPath = req.url;

  const refererPath = (() => {
    const ref = String(req.headers.referer || "");
    if (!ref) return "";
    try {
      return new URL(ref).pathname;
    } catch {
      return "";
    }
  })();
  const refererIsDashboard = refererPath.startsWith(`${HM_PREFIX}/app`);

  if (path === "/v1" || path.startsWith("/v1/")) {
    targetPort = GATEWAY_PORT;
  } else if (path === HMD_PREFIX || path.startsWith(`${HMD_PREFIX}/`)) {
    
    targetPort = DASHBOARD_PORT;
    targetPath = path.replace(HMD_PREFIX, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  } else if (path === `${HM_PREFIX}/app` || path.startsWith(`${HM_PREFIX}/app/`)) {
    targetPort = DASHBOARD_PORT;
    targetPath = path.replace(`${HM_PREFIX}/app`, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  } else if (refererIsDashboard && !path.startsWith("/webui")) {
    targetPort = DASHBOARD_PORT;
  } else if (path.startsWith("/webui/") || path === "/webui") {
    targetPort = WEBUI_PORT;
    targetPath = path.replace(/^\/webui/, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  }

  const upstream = net.createConnection(targetPort, GATEWAY_HOST, () => {
    
    const headerLines = [
      `${req.method} ${targetPath} HTTP/1.1`,
      `X-Forwarded-Host: ${req.headers.host || ""}`,
      `X-Forwarded-Proto: ${req.headers["x-forwarded-proto"] || "https"}`,
    ];
    for (const [name, value] of Object.entries(req.headers)) {
      // Skip inbound forwarded headers — re-injected above to avoid duplicates.
      const lower = name.toLowerCase();
      if (lower === "x-forwarded-host" || lower === "x-forwarded-proto") continue;
      if (Array.isArray(value)) {
        for (const v of value) headerLines.push(`${name}: ${v}`);
      } else {
        headerLines.push(`${name}: ${value}`);
      }
    }
    headerLines.push("", "");
    upstream.write(headerLines.join("\r\n"));
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  upstream.on("error", () => {
    try {
      clientSocket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    } catch {}
  });
  clientSocket.on("error", () => {
    try {
      upstream.destroy();
    } catch {}
  });
});
