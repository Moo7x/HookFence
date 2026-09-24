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
            "tsla", "amzn", "aapl", "nvda", "tslaFeed", "amznFeed", "usdgFeed", "aaplFeed", "nvdaFeed"],
  addressList: ["stocks"],
  uint: ["chainId", "suggestedFund", "feedHeartbeat", "maxShortfallBps"],
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

function envValue(env, name) {
  const line = env.split(/\r?\n/).find(l => l.startsWith(name + "="));
  return line ? line.slice(name.length + 1).trim() : "";
}

async function startSigner() {
  const env = await readFile(ENV_SRC, "utf8").catch(() => "");
  const keys = [["Alice", envValue(env, "ALICE_PRIVATE_KEY")], ["Bob", envValue(env, "BOB_PRIVATE_KEY")]];
  const deployerKey = envValue(env, "PRIVATE_KEY");
  for (const [who, k] of keys) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(k)) {
      console.error(`--testnet-signer: no ${who.toUpperCase()}_PRIVATE_KEY in contracts/.env. Run ./scripts/new-testnet-wallet.sh --role ${who.toLowerCase()}.`);
      process.exit(1);
    }
    if (deployerKey && k.toLowerCase() === deployerKey.toLowerCase()) {
      console.error(`--testnet-signer: ${who}'s key is the deployer's key. The signer never holds an admin key. Refusing.`);
      process.exit(1);
    }
  }
  if (keys[0][1].toLowerCase() === keys[1][1].toLowerCase()) {
    console.error("--testnet-signer: Alice and Bob must be two different wallets. Refusing.");
    process.exit(1);
  }

  // viem is installed only for this mode (tools/package.json, pinned to the
  // version the page itself loads), so the plain local demo needs no npm install.
  const viemDir = join(REPO, "tools", "node_modules", "viem", "_esm");
  const viem = await import(pathToFileURL(join(viemDir, "index.js")).href);
  const { privateKeyToAccount } = await import(pathToFileURL(join(viemDir, "accounts", "index.js")).href);
  const { vetTransaction } = await import(pathToFileURL(join(APP_DIR, "signer-policy.mjs")).href);

  const m = sanitiseManifest(JSON.parse(await readFile(MANIFEST_SRC, "utf8")));
  if (m.chainId !== 46630) {
    console.error(`--testnet-signer: the deployment manifest is for chain ${m.chainId}, not 46630. Refusing.`);
    process.exit(1);
  }
  const chain = {
    id: 46630, name: m.network,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [m.rpcUrl] } },
  };
  const wallets = new Map();
  for (const [, k] of keys) {
    const account = privateKeyToAccount(k);
    wallets.set(account.address.toLowerCase(), viem.createWalletClient({ account, chain, transport: viem.http(m.rpcUrl) }));
  }
  const accounts = keys.map(([, k]) => privateKeyToAccount(k).address);
  const ctx = {
    chainId: 46630, basket: m.basket, usdg: m.usdg, accounts,
    protected: [m.gateway, m.policy, m.adapter, m.poolManager, ...(m.stocks || [])].filter(Boolean),
  };

  signer = { accounts, wallets, ctx, vetTransaction, rpcUrl: m.rpcUrl };
  console.log(`test signer active on chain 46630 for Alice ${accounts[0]} and Bob ${accounts[1]}`);
  console.log("  it decodes every call and signs only the user journey; see app/signer-policy.mjs");
}

const READ_METHODS = new Set([
  "eth_chainId", "eth_blockNumber", "eth_call", "eth_estimateGas", "eth_getBalance",
  "eth_getTransactionCount", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory",
  "eth_getBlockByNumber", "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getCode",
]);

async function handleSigner(body) {
  const { id, method, params = [] } = body;
  const ok = result => ({ jsonrpc: "2.0", id, result });
  const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

  if (method === "eth_accounts" || method === "eth_requestAccounts") return ok(signer.accounts);
  if (method === "eth_chainId") return ok("0xb626");

  if (method === "eth_sendTransaction") {
    const tx = params[0] || {};
    const verdict = signer.vetTransaction(tx, signer.ctx);
    if (!verdict.ok) {
      console.log(`REFUSED ${verdict.reason}`);
      return fail(4100, `test signer refused: ${verdict.reason}`);
    }
    // Only `to`, `data` and a bounded `gas` are taken from the page. Nonce and
    // fees are filled from the chain; anything else the page sent is ignored.
    const wallet = signer.wallets.get(verdict.account.toLowerCase());
    const hash = await wallet.sendTransaction({ to: tx.to, data: tx.data, gas: tx.gas ? BigInt(tx.gas) : undefined });
    console.log(`signed  ${verdict.what}  from=${verdict.account}  tx=${hash}`);
    return ok(hash);
  }

  if (READ_METHODS.has(method)) {
    const r = await fetch(signer.rpcUrl, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    });
    return await r.json();
  }
  console.log(`UNSUPPORTED method ${String(method).slice(0, 60)}`);
  return fail(4200, `method ${method} is not supported by the test signer`);
}

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
