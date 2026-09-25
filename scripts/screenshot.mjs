// Take full-page screenshots of the site in a headless local Chrome, for design
// review and before/after evidence. Development tool only; not part of the site.
//
//   node scripts/screenshot.mjs <url> <out.png> [--width 1280] [--height 900]
//        [--mobile] [--dark] [--eval "<js run after load>"] [--wait 4000]
//
// Talks to Chrome over the DevTools protocol with Node's built-in WebSocket, so it
// needs no npm packages. A throwaway profile is used and deleted afterwards.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf(name); return i === -1 ? dflt : args[i + 1]; };
const VALUED = ["--width", "--height", "--eval", "--wait"];
const [url, out] = args.filter((a, i) => !a.startsWith("--") && !VALUED.includes(args[i - 1]));
if (!url || !out) { console.error("usage: node scripts/screenshot.mjs <url> <out.png> [options]"); process.exit(2); }
const mobile = args.includes("--mobile");
const width = Number(opt("--width", mobile ? 390 : 1280));
const height = Number(opt("--height", mobile ? 844 : 900));
const evalJs = opt("--eval", "");
const waitMs = Number(opt("--wait", 4000));

const CANDIDATES = [
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "/usr/bin/google-chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
];
const exe = CANDIDATES.find(p => existsSync(p));
if (!exe) { console.error("no Chrome or Edge found"); process.exit(1); }

const profile = mkdtempSync(join(tmpdir(), "jayo-shot-"));
const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn(exe, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "about:blank",
], { stdio: "ignore" });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(t => t.type === "page"); } catch {}
}
if (!target) { chrome.kill(); console.error("Chrome did not start"); process.exit(1); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((res, rej) => {
  const n = ++id; pending.set(n, m => m.error ? rej(new Error(`${method}: ${m.error.message}`)) : res(m.result));
  ws.send(JSON.stringify({ id: n, method, params }));
});

try {
  await send("Page.enable"); await send("Runtime.enable");
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile });
  if (args.includes("--dark")) await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
  await send("Page.navigate", { url });
  await sleep(waitMs);
  if (evalJs) {
    const r = await send("Runtime.evaluate", { expression: `(async () => { ${evalJs} })()`, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) console.error("eval error:", r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    else if (r.result?.value !== undefined) console.log("eval:", JSON.stringify(r.result.value).slice(0, 300));
  }
  const { cssContentSize } = await send("Page.getLayoutMetrics");
  const shot = await send("Page.captureScreenshot", {
    format: "png", captureBeyondViewport: true,
    clip: { x: 0, y: 0, width, height: Math.max(height, Math.ceil(cssContentSize.height)), scale: 1 },
  });
  writeFileSync(out, Buffer.from(shot.data, "base64"));
  console.log(`saved ${out} (${width}x${Math.ceil(cssContentSize.height)})`);
} finally {
  ws.close(); chrome.kill();
  await sleep(500);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
