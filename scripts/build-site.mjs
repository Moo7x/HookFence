// Build the public Jayo site for Cloudflare Pages.
//
//   node scripts/build-site.mjs                    -> site/dist
//   node scripts/build-site.mjs --refresh-manifest also rewrites
//                                                  deployments/robinhood-testnet.json
//                                                  from contracts/reports/jayo-testnet-v2.json
//
// No dependencies beyond Node, so Cloudflare's own build (or a direct upload) can
// run it as-is. Cloudflare Pages settings: build command `node scripts/build-site.mjs`,
// output directory `site/dist`.
//
// WHAT THE BUILD REFUSES TO SHIP. After assembling the site it scans every output
// file and fails if it finds: a local-only marker left behind; the local test
// signer or its token; a localhost address; anvil or any key-to-account
// constructor; any 64-hex-digit string in the page, the app or the manifest; any
// of the known keys (anvil's published ones and, if present on this machine, the
// three in contracts/.env) anywhere, including inside the vendored bundle; a file
// not on the allowlist; or a manifest field outside the public schema.

import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join, relative, dirname } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
// Overridable only so scripts/build-site.test.mjs can build from planted copies.
const APP = process.env.JAYO_SITE_APP_DIR || join(REPO, "app");
const OUT = process.env.JAYO_SITE_OUT || join(REPO, "site", "dist");
const PUBLIC_MANIFEST = process.env.JAYO_SITE_MANIFEST || join(REPO, "deployments", "robinhood-testnet.json");
const RPC = "https://rpc.testnet.chain.robinhood.com";

const { sanitiseManifest } = await import(new URL("../app/serve.mjs", import.meta.url).href);

// ------------------------------------------------------------------ manifest

const fail = msg => { console.error(`BUILD REFUSED: ${msg}`); process.exit(1); };

/** L2 block in which `address` was created, read from a forge broadcast record. */
function creationBlock(script, address) {
  const run = JSON.parse(readFileSync(join(REPO, "contracts", "broadcast", script, "46630", "run-latest.json"), "utf8"));
  const i = run.transactions.findIndex(tx => tx.transactionType === "CREATE" && tx.contractAddress?.toLowerCase() === address.toLowerCase());
  if (i === -1) fail(`${script} did not create ${address}`);
  return parseInt(run.receipts[i].blockNumber, 16);
}

if (process.argv.includes("--refresh-manifest")) {
  // Version 2 is what the site buys through; version 1 stays readable and
  // withdrawable as `legacyBasket`. The deploy blocks let the page read a
  // basket's history from its first event instead of from genesis.
  const report = JSON.parse(readFileSync(join(REPO, "contracts", "reports", "jayo-testnet-v2.json"), "utf8"));
  report.deployBlock = creationBlock("DeployJayoV2Testnet.s.sol", report.basket);
  report.legacyDeployBlock = creationBlock("DeployJayoTestnet.s.sol", report.legacyBasket);
  const clean = sanitiseManifest(report);
  mkdirSync(dirname(PUBLIC_MANIFEST), { recursive: true });
  writeFileSync(PUBLIC_MANIFEST, JSON.stringify(clean, null, 2) + "\n");
  console.log(`refreshed ${relative(REPO, PUBLIC_MANIFEST)}`);
}
const manifest = JSON.parse(readFileSync(PUBLIC_MANIFEST, "utf8"));
const reSanitised = sanitiseManifest(manifest);
if (JSON.stringify(Object.keys(reSanitised).sort()) !== JSON.stringify(Object.keys(manifest).sort())) {
  fail(`deployments/robinhood-testnet.json has fields outside the public schema: ${Object.keys(manifest).filter(k => !(k in reSanitised)).join(", ")}`);
}
if (manifest.chainId !== 46630) fail(`public manifest is for chain ${manifest.chainId}, not 46630`);
if (manifest.rpcUrl !== RPC) fail(`public manifest RPC is ${manifest.rpcUrl}, expected ${RPC}`);
if (manifest.demoControls !== false) fail("public manifest must have demoControls: false");

// ------------------------------------------------------------------ strip local-only

function strip(text, open, close, file) {
  let out = text, n = 0;
  for (;;) {
    const a = out.indexOf(open);
    if (a === -1) break;
    const b = out.indexOf(close, a);
    if (b === -1) fail(`${file}: unterminated ${open}`);
    out = out.slice(0, a) + out.slice(b + close.length);
    n++;
  }
  if (out.includes(close)) fail(`${file}: stray ${close}`);
  return { out, n };
}

const html = strip(readFileSync(join(APP, "index.html"), "utf8"), "<!-- @local-only-start -->", "<!-- @local-only-end -->", "index.html");
const js = strip(readFileSync(join(APP, "app.js"), "utf8"), "/* @local-only-start */", "/* @local-only-end */", "app.js");

// The page fetches a relative manifest so the site works at any path.
const appJs = js.out.replace("const REPORT = '/deployment.json';", "const REPORT = './deployment.json';");

// ------------------------------------------------------------------ headers

const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src https://fonts.gstatic.com",
  "img-src 'self' data:",
  `connect-src 'self' ${RPC}`,
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "object-src 'none'",
  "upgrade-insecure-requests",
].join("; ");

const HEADERS = `# Cloudflare Pages response headers. Generated by scripts/build-site.mjs.
/*
  Content-Security-Policy: ${CSP}
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: no-referrer
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), hid=(), bluetooth=()
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Strict-Transport-Security: max-age=31536000

/deployment.json
  Cache-Control: no-cache

/app/*
  Cache-Control: no-cache
`;

const NOT_FOUND = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Not found</title>
<meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family:system-ui,sans-serif;background:#05060a;color:#d1e4fa;padding:40px">
<h1>Not found</h1><p><a href="/" style="color:#d1e4fa">Back to Jayo</a></p></body></html>
`;

// ------------------------------------------------------------------ assemble

rmSync(OUT, { recursive: true, force: true });
const files = {
  "index.html": html.out,
  "404.html": NOT_FOUND,
  "app/app.js": appJs,
  "app/styles.css": readFileSync(join(APP, "styles.css"), "utf8"),
  "app/vendor/viem.js": readFileSync(join(APP, "vendor", "viem-hosted.js")),
  "deployment.json": JSON.stringify(manifest, null, 2) + "\n",
  "_headers": HEADERS,
};
for (const [rel, body] of Object.entries(files)) {
  mkdirSync(dirname(join(OUT, rel)), { recursive: true });
  writeFileSync(join(OUT, rel), body);
}

// ------------------------------------------------------------------ refuse bad output

const ALLOWED = new Set(Object.keys(files));
const walk = d => readdirSync(d).flatMap(n => statSync(join(d, n)).isDirectory() ? walk(join(d, n)) : [join(d, n)]);
for (const f of walk(OUT)) {
  const rel = relative(OUT, f).replace(/\\/g, "/");
  if (!ALLOWED.has(rel)) fail(`unexpected file in the build: ${rel}`);
}

const KNOWN_KEYS = [ // anvil's published development keys 0-2
  "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
];
const envPath = join(REPO, "contracts", ".env");
if (existsSync(envPath)) {
  for (const m of readFileSync(envPath, "utf8").matchAll(/^[A-Z_]*PRIVATE_KEY=0x([0-9a-fA-F]{64})\s*$/gm)) KNOWN_KEYS.push(m[1].toLowerCase());
}

const FORBIDDEN = [
  "@local-only", "privateKeyToAccount", "mnemonicToAccount", "hdKeyToAccount",
  "jayo-signer-token", "/signer", "localSigners", "LOCAL_ACCOUNTS", "127.0.0.1", "localhost",
  "anvil", "evm_increaseTime", "evm_mine", "PRIVATE_KEY",
];
for (const f of walk(OUT)) {
  const rel = relative(OUT, f).replace(/\\/g, "/");
  const text = readFileSync(f, "utf8");
  const lower = text.toLowerCase();
  for (const k of KNOWN_KEYS) if (lower.includes(k)) fail(`${rel} contains a private key`);
  if (rel === "app/vendor/viem.js") continue; // library constants legitimately contain long hex
  for (const w of FORBIDDEN) if (text.includes(w)) fail(`${rel} contains "${w}"`);
  const hex = text.match(/0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/);
  if (hex) fail(`${rel} contains a 64-hex-digit value (${hex[0].slice(0, 12)}…)`);
}
for (const w of ["privateKeyToAccount", "mnemonicToAccount", "hdKeyToAccount", "127.0.0.1", "localhost"]) {
  if (readFileSync(join(OUT, "app/vendor/viem.js"), "utf8").includes(w)) fail(`hosted viem bundle contains "${w}"`);
}
if (!/script-src 'self';/.test(HEADERS) || /unsafe-eval/.test(HEADERS)) fail("CSP must allow only same-origin scripts and never unsafe-eval");

// The stripped app must still be valid JavaScript.
try { execFileSync(process.execPath, ["--check", join(OUT, "app/app.js")], { stdio: "pipe" }); }
catch (e) { fail(`stripped app.js does not parse:\n${String(e.stderr)}`); }

// ------------------------------------------------------------------ report

console.log(`built ${relative(REPO, OUT)}  (removed ${html.n} local-only block(s) from index.html, ${js.n} from app.js)`);
for (const f of walk(OUT).sort()) {
  const body = readFileSync(f);
  console.log(`  ${relative(OUT, f).replace(/\\/g, "/").padEnd(20)} ${String(body.length).padStart(7)} B  sha256 ${createHash("sha256").update(body).digest("hex").slice(0, 16)}`);
}
console.log("checks passed: no keys, no local signer, no localhost, allowlisted files only, public manifest schema, CSP script-src 'self'");
