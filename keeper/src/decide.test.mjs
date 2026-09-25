// node --test keeper/src/decide.test.mjs
// The keeper must only send what DemoPriceFeed v2 would accept, and must agree
// with the Solidity pool price reader.
import { test } from "node:test";
import assert from "node:assert/strict";
import { decide, usdPrice8, BAND_WINDOW } from "./decide.mjs";

const T0 = 1_000_000n;
const base = {
  answer: 283_30000000n, updatedAt: T0, maxStepBps: 1000n, minUpdateInterval: 900n,
  maxDailyMoveBps: 2500n, bandAnchor: 283_30000000n, bandStartedAt: T0,
};

test("waits for the minimum interval", () => {
  const d = decide(base, base.answer + 1n, T0 + 899n);
  assert.equal(d.action, "wait");
  assert.equal(d.retryAt, T0 + 900n);
  assert.equal(decide(base, base.answer + 1n, T0 + 900n).action, "send");
});

test("refuses a step over 10%, allows exactly 10%", () => {
  assert.equal(decide(base, base.answer * 111n / 100n, T0 + 900n).action, "skip");
  assert.equal(decide(base, base.answer * 110n / 100n, T0 + 900n).action, "send");
});

test("refuses a move outside the 24-hour band measured from the window's anchor", () => {
  const drifted = { ...base, answer: base.answer * 121n / 100n, updatedAt: T0 + 1800n };
  const d = decide(drifted, base.answer * 130n / 100n, T0 + 2700n);
  assert.equal(d.action, "skip");
  assert.match(d.reason, /24-hour band/);
});

test("after the window ends, the band re-anchors at the standing answer", () => {
  const drifted = { ...base, answer: base.answer * 121n / 100n, updatedAt: T0 + 1800n };
  const later = T0 + BAND_WINDOW;
  assert.equal(decide(drifted, drifted.answer * 110n / 100n, later).action, "send");
});

test("a pool with no price is never published", () => {
  assert.equal(decide(base, 0n, T0 + 900n).action, "skip");
});

test("pool price matches the Solidity reader for both token orders", () => {
  // TSLA at $283.30: raw ratio of 6dp stable per 18dp equity = 283.30e6 / 1e18.
  const Q96 = 1n << 96n;
  const sqrt = x => { let r = x, y = (x + 1n) / 2n; while (y < r) { r = y; y = (x / y + y) / 2n; } return r; };
  // stable is currency1: ratio = stable per equity
  const stablePerEquityX192 = (28330n * 10n ** 4n * Q96 * Q96) / 10n ** 18n;
  const p1 = usdPrice8(sqrt(stablePerEquityX192), false);
  assert.ok(p1 > 283_29000000n && p1 < 283_31000000n, `got ${p1}`);
  // stable is currency0: ratio = equity per stable
  const equityPerStableX192 = (10n ** 18n * Q96 * Q96) / (28330n * 10n ** 4n);
  const p0 = usdPrice8(sqrt(equityPerStableX192), true);
  assert.ok(p0 > 283_29000000n && p0 < 283_31000000n, `got ${p0}`);
});
