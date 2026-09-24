// The hosted build must REFUSE to ship anything dangerous, not just happen not to.
//
//   node --test scripts/build-site.test.mjs
//
// Each case copies the real sources to a temp directory, plants one problem
// outside the local-only blocks, builds from the copy, and requires a refusal.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, cpSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("..", import.meta.url));

function buildWith(plant) {
  const dir = mkdtempSync(join(tmpdir(), "jayo-site-"));
  try {
    cpSync(join(REPO, "app"), join(dir, "app"), { recursive: true });
    cpSync(join(REPO, "deployments", "robinhood-testnet.json"), join(dir, "manifest.json"));
    plant?.(dir);
    const r = spawnSync(process.execPath, [join(REPO, "scripts", "build-site.mjs")], {
      env: { ...process.env, JAYO_SITE_APP_DIR: join(dir, "app"), JAYO_SITE_OUT: join(dir, "out"), JAYO_SITE_MANIFEST: join(dir, "manifest.json") },
      encoding: "utf8",
    });
    return { code: r.status, out: r.stdout + r.stderr, built: existsSync(join(dir, "out", "index.html")) ? readFileSync(join(dir, "out", "app", "app.js"), "utf8") : null };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
const append = (dir, rel, text) => writeFileSync(join(dir, rel), readFileSync(join(dir, rel), "utf8") + text);

test("the real sources build, with every local-only block removed", () => {
  const r = buildWith();
  assert.equal(r.code, 0, r.out);
  for (const w of ["LOCAL_ACCOUNTS", "privateKeyToAccount", "jayo-signer-token", "127.0.0.1"]) assert.ok(!r.built.includes(w), w);
});

const REFUSALS = {
  "an anvil key outside a local-only block": dir => append(dir, "app/app.js", "\nconst k = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';\n"),
  "any 64-hex value in the app": dir => append(dir, "app/app.js", "\nconst h = '0x" + "ab".repeat(32) + "';\n"),
  "a localhost URL": dir => append(dir, "app/app.js", "\nfetch('http://localhost:9999');\n"),
  "a reference to the local signer": dir => append(dir, "app/app.js", "\nfetch('/signer');\n"),
  "an unterminated local-only block": dir => append(dir, "app/app.js", "\n/* @local-only-start */\n"),
  "a key hidden inside the vendored bundle": dir => append(dir, "app/vendor/viem-hosted.js", "\n//59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d\n"),
  "a manifest field outside the public schema": dir => {
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    m.PRIVATE_KEY = "0x" + "1".repeat(64);
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(m));
  },
  "a manifest for the wrong chain": dir => {
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    m.chainId = 1;
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(m));
  },
  "a manifest that enables demo controls": dir => {
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    m.demoControls = true;
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(m));
  },
};
for (const [name, plant] of Object.entries(REFUSALS)) {
  test(`refuses ${name}`, () => {
    const r = buildWith(plant);
    assert.notEqual(r.code, 0, `built anyway:\n${r.out}`);
    assert.match(r.out, /BUILD REFUSED/);
  });
}
