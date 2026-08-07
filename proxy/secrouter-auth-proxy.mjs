// SecRouter auth proxy — the small "auth-aware proxy" that lets LibreChat reach the
// governed gateway per end-user.
//
// LibreChat logs each person in via OIDC (SecSSO) and forwards their identity in
// `x-sec-acting-user` (+ optional `x-sec-acting-groups`) on every model call, but it can
// only send a STATIC bearer to a custom endpoint. SecRouter's delegation, on the other
// hand, needs a FRESH client-credentials JWT for the `svc-secassist` service subject
// (JWTs expire). This proxy bridges the two: it obtains + refreshes that service token
// from SecSSO, then for each request pipes it upstream to SecRouter with the token as the
// Authorization bearer while passing LibreChat's acting-user headers straight through — so
// SecRouter attributes policy, budget, and audit to the real end-user (see SecRouter's
// `security.oidc.delegatingSubjects`). Short-lived tokens, no secret in the browser.
//
// Zero runtime dependencies (node: builtins only) — nothing to `npm install`, so no added
// supply-chain surface. Streams responses (SSE) unchanged.

import http from "node:http";
import https from "node:https";

const cfg = {
  port: Number(process.env.LISTEN_PORT || 8088),
  upstream: reqEnv("SECROUTER_BASE_URL").replace(/\/+$/, ""), // e.g. https://secrouter.sec.internal:47002
  tokenUrl: reqEnv("SECSSO_TOKEN_URL"), // e.g. https://secsso.sec.internal:9000/application/o/token/
  clientId: process.env.SECASSIST_CLIENT_ID || "secassist-svc",
  clientSecret: reqEnv("SECASSIST_CLIENT_SECRET"),
  scope: process.env.SECROUTER_SCOPE || "openid secrouter",
  // Refresh this many seconds before the token actually expires.
  refreshSkewSec: Number(process.env.TOKEN_REFRESH_SKEW_SEC || 60),
};

function reqEnv(name) {
  const v = process.env[name];
  if (!v || !v.trim()) {
    console.error(`secrouter-auth-proxy: ${name} is required`);
    process.exit(78); // EX_CONFIG
  }
  return v.trim();
}

// ── Service token: fetch once, cache, refresh before expiry, de-dupe concurrent fetches ──
let cached = null; // { token, expEpoch }
let inflight = null;

async function fetchToken() {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    scope: cfg.scope,
  });
  const res = await fetch(cfg.tokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`token endpoint ${res.status}: ${text.slice(0, 200)}`);
  }
  const json = await res.json();
  if (!json.access_token) throw new Error("token response missing access_token");
  const ttl = Number(json.expires_in) || 300;
  cached = { token: json.access_token, expEpoch: Math.floor(Date.now() / 1000) + ttl };
  return cached.token;
}

async function getToken() {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expEpoch - now > cfg.refreshSkewSec) return cached.token;
  if (!inflight) {
    inflight = fetchToken().finally(() => {
      inflight = null;
    });
  }
  return inflight;
}

// ── Proxy ──
const upstreamUrl = new URL(cfg.upstream);
const agent = upstreamUrl.protocol === "https:" ? https : http;

// Hop-by-hop headers we must not forward, plus the auth we replace.
const STRIP = new Set([
  "host",
  "authorization",
  "connection",
  "keep-alive",
  "proxy-authorization",
  "transfer-encoding",
  "upgrade",
  "content-length",
]);

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }

  getToken()
    .then((token) => {
      const headers = {};
      for (const [k, v] of Object.entries(req.headers)) {
        if (!STRIP.has(k.toLowerCase())) headers[k] = v; // acting-user/groups pass through here
      }
      headers["authorization"] = `Bearer ${token}`;

      const outbound = agent.request(
        {
          protocol: upstreamUrl.protocol,
          hostname: upstreamUrl.hostname,
          port: upstreamUrl.port,
          method: req.method,
          path: req.url,
          headers,
        },
        (upRes) => {
          res.writeHead(upRes.statusCode || 502, upRes.headers);
          upRes.pipe(res); // stream body / SSE unchanged
        },
      );
      outbound.on("error", (err) => {
        console.error(`secrouter-auth-proxy: upstream error: ${err.message}`);
        if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "upstream_unreachable", type: "secassist_proxy" } }));
      });
      req.pipe(outbound);
    })
    .catch((err) => {
      console.error(`secrouter-auth-proxy: token error: ${err.message}`);
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "service_token_unavailable", type: "secassist_proxy" } }));
    });
});

server.listen(cfg.port, "0.0.0.0", () => {
  console.log(
    `secrouter-auth-proxy: :${cfg.port} → ${cfg.upstream} (client_id=${cfg.clientId}, scope="${cfg.scope}")`,
  );
});
