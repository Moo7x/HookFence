// Proves the local server cannot be made to hand out secrets.
//
//   node --test app/serve.test.mjs
//
// It plants canary values in .env and contracts/.env (only where no such file
// exists, and removes only what it planted), then tries to read them — and
// .git/config, and the server's own source — through every path shape that has
// historically defeated naive static servers. Every one must be a 404 whose body
// contains no canary.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { request } from "node:http";
import { connect } from "node:net";
import { existsSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const PORT = 5199;
process.env.JAYO_PORT = String(PORT);
const { createJayoServer, sanitiseManifest } = await import("./serve.mjs");

const REPO = fileURLToPath(new URL("..", import.meta.url));
const CANARY = "JAYO_CANARY_" + Math.random().toString(36).slice(2);
const planted = [];
let server;

function plant(rel) {
  const p = join(REPO, rel);
  if (existsSync(p)) return; // never touch a real one
  writeFileSync(p, `PRIVATE_KEY=${CANARY}\n`);
  planted.push(p);
}

function get(path, { host = `127.0.0.1:${PORT}`, method = "GET", headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port: PORT, path, method, headers: { host, ...headers } }, res => {
      let body = "";
      res.on("data", c => (body += c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

before(async () => {
  plant(".env");
  plant(join("contracts", ".env"));
  server = createJayoServer();
  await new Promise(r => server.listen(PORT, "127.0.0.1", r));
});

after(async () => {
  await new Promise(r => server.close(r));
  for (const p of planted) rmSync(p);
});

test("binds to the loopback interface only", () => {
  assert.equal(server.address().address, "127.0.0.1");
});

const MUST_NOT_SERVE = [
  "/.env", "/contracts/.env", "/.env.example",
  "/.git/config", "/.git/HEAD", "/.gitignore",
  "/app/serve.mjs", "/app/serve.test.mjs", "/app/",
  "/contracts/reports/jayo-deployment.json", "/contracts/foundry.toml", "/contracts/cache/",
  "/app/../.env", "/app/../.git/config", "/app/..%2f.env", "/app/..%2F..%2F.git%2Fconfig",
  "/%2e%2e/.env", "/%2e%2e%2f.env", "/..%5c.env", "/..\\.env", "//.env", "/./.env",
  "/app/app.js/../../.env", "/APP/APP.JS", "/index.html%00.js", "/app/app.js%00",
  "/deployment.json/../.env",
];

for (const path of MUST_NOT_SERVE) {
  test(`does not serve ${path}`, async () => {
    const r = await get(path);
    assert.equal(r.status, 404, `${path} returned ${r.status}`);
    assert.ok(!r.body.includes(CANARY), `${path} leaked the canary`);
    assert.ok(!r.body.includes("[remote"), `${path} leaked git config`);
  });
}

test("the canary really is on disk, so the 404s above mean something", () => {
  const somewhere = [join(REPO, ".env"), join(REPO, "contracts", ".env")].filter(existsSync);
  assert.ok(somewhere.length > 0);
  if (planted.length) assert.ok(readFileSync(planted[0], "utf8").includes(CANARY));
});

test("refuses a foreign Host header (DNS rebinding)", async () => {
  for (const host of ["evil.example", "evil.example:5199", "127.0.0.1.nip.io:5199", "127.0.0.1:80"]) {
    const r = await get("/", { host });
    assert.equal(r.status, 421, `Host "${host}" returned ${r.status}`);
  }
});

// Node's HTTP client silently supplies a Host when given an empty one, so the
// no-Host case has to be written on the wire by hand.
test("refuses a request with no Host header at all", async () => {
  const status = await new Promise((resolve, reject) => {
    const sock = connect(PORT, "127.0.0.1", () => sock.write("GET /.env HTTP/1.0\r\n\r\n"));
    let buf = "";
    sock.on("data", d => (buf += d));
    sock.on("end", () => resolve(Number(buf.split(" ")[1])));
    sock.on("error", reject);
  });
  assert.equal(status, 421);
});

test("serves the page, with a restrictive content security policy", async () => {
  const r = await get("/");
  assert.equal(r.status, 200);
  assert.match(r.body, /<title>/);
  assert.match(r.headers["content-security-policy"], /frame-ancestors 'none'/);
  assert.equal(r.headers["x-content-type-options"], "nosniff");
});

test("the page runs no code from any other origin", async () => {
  const page = await get("/");
  const csp = page.headers["content-security-policy"];
  const scriptSrc = csp.split(";").map(s => s.trim()).find(s => s.startsWith("script-src"));
  assert.equal(scriptSrc, "script-src 'self'", "script-src must allow our own origin only");
  assert.ok(!/<script[^>]+src="https?:/i.test(page.body), "no external <script src>");

  const js = await get("/app/app.js");
  assert.equal(js.status, 200);
  const imports = [...js.body.matchAll(/^\s*import[\s\S]*?from\s+['"]([^'"]+)['"]/gm)].map(m => m[1]);
  assert.ok(imports.length > 0);
  for (const spec of imports) assert.ok(spec.startsWith("/"), `app.js imports ${spec} from another origin`);

  const vendor = await get("/app/vendor/viem.js");
  assert.equal(vendor.status, 200);
  assert.ok(!/\bimport\s*\(?\s*['"]https?:/.test(vendor.body), "the bundle does not fetch code at runtime");
});

test("only GET and HEAD reach static routes", async () => {
  assert.equal((await get("/", { method: "POST" })).status, 405);
  assert.equal((await get("/deployment.json", { method: "PUT" })).status, 405);
});

test("the signing endpoint does not exist unless explicitly enabled", async () => {
  const r = await get("/signer", { method: "POST", headers: { origin: `http://127.0.0.1:${PORT}` } });
  assert.equal(r.status, 404);
});

test("the manifest keeps only allowlisted, well-formed fields", () => {
  const hostile = {
    basket: "0x" + "a".repeat(40),
    usdg: "not-an-address",
    PRIVATE_KEY: "0x" + "1".repeat(64),
    privateKey: "0x" + "2".repeat(64),
    mnemonic: "abandon abandon abandon",
    rpcUrl: "javascript:alert(1)",
    explorer: "https://explorer.testnet.chain.robinhood.com",
    chainId: 46630,
    stocks: ["0x" + "b".repeat(40), "0xnope"],
    nested: { PRIVATE_KEY: "x" },
    demoControls: "yes",
  };
  const clean = sanitiseManifest(hostile);
  assert.deepEqual(Object.keys(clean).sort(), ["basket", "chainId", "explorer"].sort());
  assert.ok(!JSON.stringify(clean).includes("1111"));
});

test("the live manifest route returns only schema keys", async () => {
  const r = await get("/deployment.json");
  if (r.status === 404) return; // no deployment on this machine yet
  const keys = Object.keys(JSON.parse(r.body));
  const allowed = new Set(["poolManager", "usdg", "basket", "gateway", "policy", "adapter", "deployer",
    "tsla", "amzn", "aapl", "nvda", "tslaFeed", "amznFeed", "usdgFeed", "aaplFeed", "nvdaFeed", "stocks",
    "chainId", "suggestedFund", "feedHeartbeat", "maxShortfallBps", "demoControls", "network", "warning",
    "priceSource", "rpcUrl", "explorer", "localSigners"]);
  for (const k of keys) assert.ok(allowed.has(k), `unexpected key ${k}`);
});
