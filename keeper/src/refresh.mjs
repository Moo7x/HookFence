// Read the pools and the feeds, decide, and (unless dry-running) publish.
// Shared by the scheduled Worker (index.mjs) and the local dry run (cli.mjs).

import { encodeAbiParameters, keccak256 } from "viem";
import { decide, usdPrice8 } from "./decide.mjs";

const POOLS_SLOT = 6n;
const FEE = 3000;
const TICK_SPACING = 60;
const ZERO = "0x0000000000000000000000000000000000000000";
const RUSDG_USD = 100_000_000n; // $1.00, 8 dp: rUSDG's feed is a fixed heartbeat

export const FEED_ABI = [
  { type: "function", name: "latestRoundData", stateMutability: "view", inputs: [], outputs: [
    { type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] },
  { type: "function", name: "maxStepBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  { type: "function", name: "minUpdateInterval", stateMutability: "view", inputs: [], outputs: [{ type: "uint32" }] },
  { type: "function", name: "maxDailyMoveBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  { type: "function", name: "bandAnchor", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
  { type: "function", name: "bandStartedAt", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "updater", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "setAnswer", stateMutability: "nonpayable", inputs: [{ type: "int256" }], outputs: [] },
];
const PM_ABI = [
  { type: "function", name: "extsload", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bytes32" }] },
];

function poolStateSlot(stable, stock) {
  const [c0, c1] = BigInt(stable) < BigInt(stock) ? [stable, stock] : [stock, stable];
  const id = keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [c0, c1, FEE, TICK_SPACING, ZERO],
  ));
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [id, POOLS_SLOT]));
}

async function poolPrice8(pub, cfg, stock) {
  const word = await pub.readContract({ address: cfg.poolManager, abi: PM_ABI, functionName: "extsload", args: [poolStateSlot(cfg.usdg, stock)] });
  const sqrtPriceX96 = BigInt(word) & ((1n << 160n) - 1n);
  return usdPrice8(sqrtPriceX96, BigInt(cfg.usdg) < BigInt(stock));
}

async function feedState(pub, feed) {
  const read = functionName => pub.readContract({ address: feed, abi: FEED_ABI, functionName });
  const [round, maxStepBps, minUpdateInterval, maxDailyMoveBps, bandAnchor, bandStartedAt] = await Promise.all([
    read("latestRoundData"), read("maxStepBps"), read("minUpdateInterval"), read("maxDailyMoveBps"), read("bandAnchor"), read("bandStartedAt"),
  ]);
  return {
    answer: round[1], updatedAt: round[3],
    maxStepBps: BigInt(maxStepBps), minUpdateInterval: BigInt(minUpdateInterval),
    maxDailyMoveBps: BigInt(maxDailyMoveBps), bandAnchor, bandStartedAt,
  };
}

/**
 * cfg: { poolManager, usdg, feeds: [{ label, feed, stock | null }] }
 * wallet: a viem wallet client with an account, or null to only report.
 */
export async function refreshAll({ pub, wallet, cfg, log = console.log }) {
  const now = (await pub.getBlock()).timestamp;
  const results = [];
  for (const f of cfg.feeds) {
    const next = f.stock ? await poolPrice8(pub, cfg, f.stock) : RUSDG_USD;
    const state = await feedState(pub, f.feed);
    const d = decide(state, next, now);
    const age = now - state.updatedAt;
    const entry = { label: f.label, action: d.action, reason: d.reason, previous: state.answer, next, ageSeconds: age };
    if (d.moveBps !== undefined) entry.moveBps = d.moveBps;

    if (d.action === "send" && wallet) {
      try {
        const { request } = await pub.simulateContract({ address: f.feed, abi: FEED_ABI, functionName: "setAnswer", args: [next], account: wallet.account });
        const hash = await wallet.writeContract(request);
        const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
        entry.tx = hash;
        entry.status = receipt.status;
      } catch (e) {
        entry.action = "failed";
        entry.error = (e.shortMessage || e.message || String(e)).slice(0, 200);
      }
    }
    results.push(entry);
    log(JSON.stringify(entry, (k, v) => (typeof v === "bigint" ? v.toString() : v)));
  }
  return results;
}
