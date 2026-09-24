// Serve the BUILT public site (site/dist) the way Cloudflare Pages will: the
// same files, the same `_headers` rules, 404.html for anything else.
//
//   node scripts/serve-site.mjs                 http://127.0.0.1:8788
//   node scripts/serve-site.mjs --test-wallet   also stands in for a browser wallet
//
// --test-wallet exists only to verify the hosted build end to end from a browser
// with no wallet extension. It injects a small EIP-1193 provider into the served
// page and answers it, same-origin, with the local test signer (Alice's and Bob's
// keys only, decoded allowlist - app/signer-policy.mjs). None of it is in
// site/dist: the build refuses to emit anything that references it, and this
// script only adds it to the response on the fly. The site's own CSP is applied
// unchanged, so the verification runs under the production policy.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { readFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join, normalize, extname } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const DIST = join(REPO, "site", "dist");
const HOST = "127.0.0.1";
const PORT = Number(process.env.JAYO_SITE_PORT || 8788);
const TEST_WALLET = process.argv.includes("--test-wallet");
const TOKEN = randomBytes(24).toString("hex");
const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);
const ORIGINS = new Set([`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`]);

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json" };

// ---- Cloudflare `_headers` semantics, enough for our file: path patterns with a
//      trailing `*`, each followed by indented `Name: value` lines. All matching
//      rules apply, in order.
export function parseHeaders(text) {
  const rules = [];
  let cur = null;
  for (const raw of text.split(/\r?\n/)) {
    if (!raw.trim() || raw.trim().startsWith("#")) continue;
    if (!/^\s/.test(raw)) { cur = { pattern: raw.trim(), headers: [] }; rules.push(cur); continue; }
    const i = raw.indexOf(":");
    cur.headers.push([raw.slice(0, i).trim(), raw.slice(i + 1).trim()]);
  }
  return rules;
}
export function headersFor(rules, path) {
  const out = {};
  for (const r of rules) {
    const p = r.pattern;
    const hit = p.endsWith("*") ? path.startsWith(p.slice(0, -1)) : path === p;
    if (hit) for (const [k, v] of r.headers) out[k.toLowerCase()] = v;
  }
  return out;
}

const rules = parseHeaders(readFileSync(join(DIST, "_headers"), "utf8"));

let signer = null;
if (TEST_WALLET) {
  const { createTestSigner } = await import(pathToFileURL(join(REPO, "app", "test-signer.mjs")).href);
  const manifest = JSON.parse(readFileSync(join(DIST, "deployment.json"), "utf8"));
  signer = await createTestSigner({ envPath: join(REPO, "contracts", ".env"), manifest });
}

const TEST_WALLET_JS = `// LOCAL VERIFICATION ONLY - injected by scripts/serve-site.mjs --test-wallet.
(() => {
  const token = document.querySelector('meta[name="jayo-test-wallet-token"]').content;
  const accounts = ${JSON.stringify(signer?.accounts || [])};
  let current = Number(sessionStorage.getItem('jayoTestWallet') || 0);
  const listeners = {};
  let id = 0;
  async function rpc(method, params) {
    const r = await fetch('/__test_signer', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-jayo-test-wallet': token },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
    const out = await r.json();
    if (out.error) throw Object.assign(new Error(out.error.message), { code: out.error.code });
    return out.result;
  }
  window.ethereum = {
    isJayoTestWallet: true,
    async request({ method, params }) {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [accounts[current]];
      if (method === 'eth_chainId') return '0xb626';
      if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null;
      if (method === 'eth_sendTransaction' && params?.[0]) params = [{ ...params[0], from: accounts[current] }];
      return rpc(method, params);
    },
    on(ev, fn) { (listeners[ev] ||= []).push(fn); },
    removeListener(ev, fn) { listeners[ev] = (listeners[ev] || []).filter(f => f !== fn); },
  };
  window.__testWallet = {
    accounts,
    use(i) { current = i; sessionStorage.setItem('jayoTestWallet', String(i)); (listeners.accountsChanged || []).forEach(f => f([accounts[i]])); },
  };
  const bar = document.createElement('div');
  bar.textContent = 'LOCAL VERIFICATION ONLY - a test wallet stands in for a browser wallet: ' + accounts[current];
  bar.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99;background:#7a1f1f;color:#fff;font:12px monospace;padding:4px 10px';
  document.addEventListener('DOMContentLoaded', () => document.body.appendChild(bar));
})();
`;

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

createServer(async (req, res) => {
  if (!ALLOWED_HOSTS.has(req.headers.host || "")) return send(res, 421, {}, "misdirected request");
  let path = decodeURIComponent((req.url || "/").split("?")[0]);

  if (TEST_WALLET && path === "/__test_signer") {
    if (req.method !== "POST" || !ORIGINS.has(req.headers.origin || "") || req.headers["x-jayo-test-wallet"] !== TOKEN) {
      return send(res, 403, {}, "forbidden");
    }
    let raw = "";
    for await (const c of req) raw += c;
    try { return send(res, 200, { "content-type": "application/json" }, JSON.stringify(await signer.handle(JSON.parse(raw)))); }
    catch (e) { return send(res, 200, { "content-type": "application/json" }, JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: String(e.shortMessage || e.message) } })); }
  }
  if (TEST_WALLET && path === "/__test_wallet.js") {
    return send(res, 200, { ...headersFor(rules, path), "content-type": TYPES[".js"] }, TEST_WALLET_JS);
  }
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, {}, "method not allowed");

  if (path === "/") path = "/index.html";
  const file = normalize(join(DIST, path));
  const inside = file.startsWith(DIST) && !path.includes("..") && !path.includes("\\") && !path.split("/").some(s => s.startsWith("_"));
  if (!inside || !existsSync(file) || path.endsWith("/")) {
    return send(res, 404, { ...headersFor(rules, path), "content-type": TYPES[".html"] }, await readFile(join(DIST, "404.html")));
  }
  let body = await readFile(file);
  if (TEST_WALLET && path === "/index.html") {
    body = body.toString("utf8").replace('<script type="module"',
      `<meta name="jayo-test-wallet-token" content="${TOKEN}">\n<script src="/__test_wallet.js"></script>\n<script type="module"`);
  }
  send(res, 200, { ...headersFor(rules, path), "content-type": TYPES[extname(file)] || "application/octet-stream" }, body);
}).listen(PORT, HOST, () => {
  console.log(`serving site/dist at http://${HOST}:${PORT} with its _headers${TEST_WALLET ? "  [TEST WALLET: " + signer.accounts.join(", ") + "]" : ""}`);
});
