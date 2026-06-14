"use strict";

const http = require("http");
const fs = require("fs");

const config = require("./lib/config");
const auth = require("./lib/auth");
const views = require("./lib/views");
const proxy = require("./lib/proxy");
const status = require("./lib/status");

const {
  PORT,
  GATEWAY_PORT,
  DASHBOARD_PORT,
  TELEGRAM_WEBHOOK_PORT,
  WEBUI_PORT,
  API_SERVER_KEY,
  WEBUI_HAS_PASSWORD,
  HM_PREFIX,
  HMD_PREFIX,
  LOGIN_PATH,
  PRIMARY_UI,
  HF_SPACE_URL,
  isSpacePrivate,
  isPrivacyDetectionDone,
  privacyDetectionReady,
  initPrivacyDetection,
} = config;
const {
  handleLogin,
  requireAuth,
  isAuthorized,
  getBearerToken,
  wantsHtml,
  loginUrl,
} = auth;
const {
  renderStatusPage,
  renderTiles,
  renderPrivateRedirect,
  escapeHtml,
  isDashboardAssetPath,
} = views;
const { proxyRequest, proxyDashboard, redirect, isWebuiExecPath, handleUpgrade } = proxy;
const { statusPayload } = status;

initPrivacyDetection();

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
const dashboardRootRoutesList = [...dashboardRootRoutes];

const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, "http://localhost");
  const path = parsed.pathname;

  if (path === LOGIN_PATH) {
    await handleLogin(req, res, parsed);
    return;
  }

  if (path === "/health") {
    const data = await statusPayload();
    // Always 200: HF kills containers on 503 even when supervisor would recover; truthful status is in body.
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

  // Client-side privacy fallback; no auth needed — not sensitive.
  if (path === "/api/is-private") {
    if (!isPrivacyDetectionDone()) await privacyDetectionReady;
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    return res.end(JSON.stringify({ isPrivate: isSpacePrivate() }));
  }

  if (path === "/hf-redirect" || path === "/hf-redirect/") {
    if (HF_SPACE_URL) {
      res.writeHead(302, { location: HF_SPACE_URL, "cache-control": "no-store" });
      return res.end();
    }
    res.writeHead(404, { "content-type": "text/plain" });
    return res.end("SPACE_ID not configured.");
  }

  if (path === "/env-builder" || path === "/env-builder/") {
    if (!requireAuth(req, res)) return;
    try {
      const html = fs.readFileSync(
        require("path").join(__dirname, "public", "env-builder.html"),
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
        require("path").join(__dirname, "public", "env-builder.js"),
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

  if (path === "/env-builder-data.js") {
    if (!requireAuth(req, res)) return;
    try {
      const js = fs.readFileSync(
        require("path").join(__dirname, "public", "env-builder-data.js"),
        "utf8",
      );
      res.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
      });
      res.end(js);
    } catch {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("env-builder-data.js not found");
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

  if (path === `${HM_PREFIX}/logs` || path.startsWith(`${HM_PREFIX}/logs/`)) {
    if (!requireAuth(req, res)) return;
    const logDir = process.env.HERMES_HOME
      ? `${process.env.HERMES_HOME}/logs`
      : "/opt/data/logs";
    const logFiles = ["dashboard.log", "gateway.log", "webui.log"];
    if (path.startsWith(`${HM_PREFIX}/logs/`)) {
      const name = path.slice(`${HM_PREFIX}/logs/`.length);
      if (!logFiles.includes(name)) {
        res.writeHead(404, { "content-type": "text/plain" });
        res.end("Not found");
        return;
      }
      try {
        const tailRaw = parsed.searchParams.get("tail");
        const tailNum = Number(tailRaw);
        const tail = Number.isFinite(tailNum) && tailNum > 0
          ? Math.min(tailNum, 5000)
          : 200;
        const content = fs.readFileSync(`${logDir}/${name}`, "utf8");
        const lines = content.split("\n");
        const sliced = lines.slice(-tail);
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
        res.end(sliced.join("\n"));
      } catch {
        res.writeHead(404, { "content-type": "text/plain" });
        res.end(`Log file ${name} not found`);
      }
      return;
    }
    const links = logFiles.map((f) => {
      const size = (() => { try { return fs.statSync(`${logDir}/${f}`).size; } catch { return 0; } })();
      return `<li><a href="${HM_PREFIX}/logs/${f}?tail=200">${escapeHtml(f)}</a> (${(size / 1024).toFixed(1)} KB)</li>`;
    }).join("");
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><html><head><meta charset="utf-8"/><title>HuggingMes Logs</title>
<style>body{font-family:monospace;background:#0a0a12;color:#e0e0e0;padding:20px}a{color:#38bdf8}h1{font-size:1.2rem}li{margin:8px 0}</style></head>
<body><h1>Service Logs</h1><p>Append <code>?tail=N</code> to limit lines (default 200).</p><ul>${links}</ul></body></html>`);
    return;
  }

  if (path === "/dashboard" || path === "/dashboard/") {
    redirect(res, `${HM_PREFIX}${parsed.search}`);
    return;
  }

  if (dashboardRootRoutes.has(path) || dashboardRootRoutesList.some((r) => path.startsWith(r + "/"))) {
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
  // Private Spaces: redirect direct .hf.space hits; suppress in iframes (X-Frame-Options blocks navigation).
  const isHtmlReq = (req.headers.accept || "").includes("text/html");
  const isDirectHfSpaceReq = isSpacePrivate() &&
    HF_SPACE_URL &&
    isHtmlReq &&
    typeof req.headers.host === "string" &&
    req.headers.host.endsWith(".hf.space");

  if (isDirectHfSpaceReq && !isPrivacyDetectionDone()) {
    await Promise.race([
      privacyDetectionReady,
      new Promise((r) => setTimeout(r, 1500)),
    ]);
  }

  if (path === "/" && isDirectHfSpaceReq && isSpacePrivate()) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(renderPrivateRedirect(HF_SPACE_URL));
  }

  if (isWebuiExecPath(path) && !WEBUI_HAS_PASSWORD) {
    if (!requireAuth(req, res)) return;
  }

  proxyRequest(req, res, WEBUI_PORT);
});

// Disable socket timeout for HF LB's long-lived streams; keepAliveTimeout > LB's ~60s idle window.
server.timeout = 0;
server.keepAliveTimeout = 65000;

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Hermes WebUI router listening on 0.0.0.0:${PORT}`);
});

server.on("upgrade", handleUpgrade);
