// Jayo local server.
//
//   node app/serve.mjs                    local demo  -> http://127.0.0.1:5173
//   node app/serve.mjs --testnet-signer   also signs testnet transactions for the
//                                         page, as the two demo USER wallets in
//                                         contracts/.env (never the deployer)
//
// WHAT THIS SERVES, AND NOTHING ELSE
//
//   GET /                   app/index.html
//   GET /app/app.js         app/app.js
//   GET /app/styles.css     app/styles.css
//   GET /app/vendor/viem.js app/vendor/viem.js (pinned, reproducible bundle)
//   GET /deployment.json    a SANITISED copy of contracts/reports/jayo-deployment.json
//
// An earlier version served the repository root, so /.git/config, /.env.example,
// the Foundry cache and any contracts/.env were all one request away, on every
// network interface. There is now no path-to-file mapping at all: a request either
// names one of the four routes above exactly or it is a 404. See
// app/serve.test.mjs, which proves it against canary secrets.
//
// It binds to 127.0.0.1 only and refuses any Host header that is not this
// machine, which also closes DNS rebinding (a hostile domain resolving to
// 127.0.0.1 still sends its own name as Host).

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";

const HOST = "127.0.0.1"; // deliberately not configurable
const PORT = Number(process.env.JAYO_PORT || 5173);
const APP_DIR = fileURLToPath(new URL(".", import.meta.url));
const REPO = fileURLToPath(new URL("..", import.meta.url));
// Overridable only so app/signer.test.mjs can point a signer-on server at a
// throwaway manifest and a fake RPC. Nothing here is reachable over HTTP.
const MANIFEST_SRC = process.env.JAYO_MANIFEST_SRC || join(REPO, "contracts", "reports", "jayo-deployment.json");
const ENV_SRC = process.env.JAYO_SIGNER_ENV || join(REPO, "contracts", ".env");

const STATIC = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/index.html": ["index.html", "text/html; charset=utf-8"],
  "/app/app.js": ["app.js", "text/javascript; charset=utf-8"],
  "/app/styles.css": ["styles.css", "text/css; charset=utf-8"],
  "/app/vendor/viem.js": ["vendor/viem.js", "text/javascript; charset=utf-8"],
};

const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);
const ALLOWED_ORIGINS = new Set([`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`]);

const SIGNER_ON = process.argv.includes("--testnet-signer");
const SIGNER_TOKEN = randomBytes(24).toString("hex");

// ---------------------------------------------------------------- manifest ---

// Every key the page may see, and what shape it must have. Anything not listed
// is dropped; anything listed but malformed is dropped. A deploy script that
// one day writes something sensitive into its report cannot leak it through here.
const ADDR = /^0x[0-9a-fA-F]{40}$/;
const MANIFEST_SCHEMA = {
  address: ["poolManager", "usdg", "basket", "gateway", "policy", "adapter", "deployer",
            "tsla", "amzn", "aapl", "nvda", "tslaFeed", "amznFeed", "usdgFeed", "aaplFeed", "nvdaFeed", "multicall3",
    "legacyBasket", "legacyBasket2", "renderer", "updater"],
  addressList: ["stocks"],
  uint: ["chainId", "suggestedFund", "feedHeartbeat", "maxShortfallBps", "feedMinInterval", "firstTokenId",
    "deployBlock", "legacyDeployBlock", "legacyDeployBlock2"],
  bool: ["demoControls"],
  text: ["network", "warning", "priceSource"],
  url: ["rpcUrl", "explorer"],
};

export function sanitiseManifest(raw) {
  const out = {};
  for (const k of MANIFEST_SCHEMA.address) if (typeof raw[k] === "string" && ADDR.test(raw[k])) out[k] = raw[k];
  for (const k of MANIFEST_SCHEMA.addressList) {
    if (Array.isArray(raw[k]) && raw[k].every(a => typeof a === "string" && ADDR.test(a))) out[k] = raw[k];
  }
  for (const k of MANIFEST_SCHEMA.uint) if (Number.isSafeInteger(raw[k]) && raw[k] >= 0) out[k] = raw[k];
  for (const k of MANIFEST_SCHEMA.bool) if (typeof raw[k] === "boolean") out[k] = raw[k];
  for (const k of MANIFEST_SCHEMA.text) if (typeof raw[k] === "string" && raw[k].length <= 400) out[k] = raw[k];
  for (const k of MANIFEST_SCHEMA.url) {
    if (typeof raw[k] === "string" && /^(https:\/\/[a-z0-9.-]+(\/[\w./-]*)?|http:\/\/127\.0\.0\.1:\d+)$/i.test(raw[k])) out[k] = raw[k];
  }
  return out;
}

async function manifest() {
  const raw = JSON.parse(await readFile(MANIFEST_SRC, "utf8"));
  const m = sanitiseManifest(raw);
  if (SIGNER_ON && signer) m.localSigners = signer.accounts;
  return m;
}

// ------------------------------------------------------------------ signer ---
//
// Present only with --testnet-signer. It exists so the page can be driven end to
// end on the public testnet from a browser that has no wallet extension. A
// browser wallet, or the scripted CLI journey (script/PublicJourney.s.sol), is
// the preferred way to send public-testnet transactions; this is the fallback.
//
// What makes it tolerable:
//
//   - It holds only the two demo USER keys (ALICE_PRIVATE_KEY, BOB_PRIVATE_KEY).
//     It refuses to start if either equals the deployer's key, so no owner-only
//     function on any Jayo contract can be signed through it, whatever the page
//     asks for.
//   - Every eth_sendTransaction is DECODED and checked by app/signer-policy.mjs:
//     approve only to the basket; create/copy under a spend cap; the three
//     withdrawals; safeTransferFrom only from the sender and never to a zero or
//     Jayo address. Everything else, and any non-canonical calldata, is refused.
//   - The page contains no third-party code (viem is vendored, CSP script-src
//     'self'), so nothing but our own scripts can read the per-run token.
//   - Only a same-origin request, with the right Host, Origin and token, reaches
//     it. Keys never leave this process and are never logged.

let signer = null;

async function startSigner() {
  const { createTestSigner } = await import(pathToFileURL(join(APP_DIR, "test-signer.mjs")).href);
  const m = sanitiseManifest(JSON.parse(await readFile(MANIFEST_SRC, "utf8")));
  try {
    signer = await createTestSigner({ envPath: ENV_SRC, manifest: m });
  } catch (e) {
    console.error(`--testnet-signer: ${e.message} Refusing.`);
    process.exit(1);
  }
  console.log(`test signer active on chain 46630 for Alice ${signer.accounts[0]} and Bob ${signer.accounts[1]}`);
  console.log("  it decodes every call and signs only the user journey; see app/signer-policy.mjs");
}

const handleSigner = body => signer.handle(body);

// ------------------------------------------------------------------ server ---

const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
  "cache-control": "no-store",
  "content-security-policy": [
    "default-src 'self'",
    // No third-party script origin at all: viem is vendored (app/vendor/viem.js),
    // so nothing loaded into the page can come from anyone else's server.
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com",
    "img-src 'self' data:",
    "connect-src 'self' http://127.0.0.1:8545 https://rpc.testnet.chain.robinhood.com",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; "),
};

function send(res, status, type, body) {
  res.writeHead(status, { ...SECURITY_HEADERS, "content-type": type });
  res.end(body);
}

export function createJayoServer() {
  return createServer(async (req, res) => {
    // DNS rebinding: a hostile name that resolves here still carries its own Host.
    if (!ALLOWED_HOSTS.has(req.headers.host || "")) return send(res, 421, "text/plain", "misdirected request");

    const path = (req.url || "/").split("?")[0];

    if (path === "/signer") {
      if (!SIGNER_ON || !signer) return send(res, 404, "text/plain", "not found");
      if (req.method !== "POST") return send(res, 405, "text/plain", "method not allowed");
      if (!ALLOWED_ORIGINS.has(req.headers.origin || "")) return send(res, 403, "text/plain", "forbidden");
      if (req.headers["x-jayo-signer-token"] !== SIGNER_TOKEN) return send(res, 403, "text/plain", "forbidden");
      let raw = "";
      for await (const chunk of req) { raw += chunk; if (raw.length > 64_000) return send(res, 413, "text/plain", "too large"); }
      try {
        const out = await handleSigner(JSON.parse(raw));
        return send(res, 200, "application/json", JSON.stringify(out));
      } catch (e) {
        // Logged because a silent failure here sent viem to its wallet_sendTransaction
        // fallback, and the page then showed only "method not supported".
        const message = String(e.shortMessage || e.message || e);
        console.log(`ERROR   ${message.split("\n")[0].slice(0, 200)}`);
        return send(res, 200, "application/json",
          // -32603 (internal), not -32000: viem reads -32000 as "invalid input" and
          // retries as wallet_sendTransaction, which buried the real error.
          JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message } }));
      }
    }

    if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "text/plain", "method not allowed");

    if (path === "/deployment.json") {
      try { return send(res, 200, "application/json", JSON.stringify(await manifest())); }
      catch { return send(res, 404, "text/plain", "no deployment"); }
    }

    const entry = STATIC[path];
    if (!entry) return send(res, 404, "text/plain", "not found");

    let body = await readFile(join(APP_DIR, entry[0]));
    if (entry[0] === "index.html" && SIGNER_ON) {
      body = body.toString("utf8").replace("</head>",
        `<meta name="jayo-signer-token" content="${SIGNER_TOKEN}">\n</head>`);
    }
    return send(res, 200, entry[1], body);
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  if (SIGNER_ON) await startSigner();
  createJayoServer().listen(PORT, HOST, () => {
    console.log(`Jayo running at http://${HOST}:${PORT}  (bound to localhost only)`);
  });
}
