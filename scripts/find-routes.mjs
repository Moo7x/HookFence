// Find usable Uniswap v4 routes between a stablecoin and Stock Tokens.
//
//   node scripts/find-routes.mjs mainnet   AAPL TSLA AMZN NVDA
//   node scripts/find-routes.mjs testnet   TSLA AMZN
//
// For each token: every pool the PoolManager ever initialised against the
// stablecoin, filtered to HOOKLESS pools, then each one's current state read with
// extsload - active liquidity, spot price, fee - and the price compared with
// Chainlink where a mainnet feed exists. Junk pools (fees of 49-99.99%, prices off
// by 40-1700%) are common, so price agreement is shown rather than assumed.
//
// Uses the pinned viem in tools/ for keccak and ABI encoding.

import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const { keccak256, encodeAbiParameters, pad } = await import(pathToFileURL(join(REPO, "tools", "node_modules", "viem", "_esm", "index.js")).href);

const NETS = {
  mainnet: {
    rpc: "https://rpc.mainnet.chain.robinhood.com",
    stable: ["USDG", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"],
    tokens: { // canonical, from docs.robinhood.com/chain/contracts (on-chain registry)
      AAPL: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
      TSLA: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
      AMZN: "0x12f190a9F9d7D37a250758b26824B97CE941bF54",
      NVDA: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
    },
    feeds: { // Chainlink, from feeds-robinhood-mainnet.json
      AAPL: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
      TSLA: "0x4A1166a659A55625345e9515b32adECea5547C38",
      AMZN: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
      NVDA: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
    },
  },
  testnet: {
    rpc: "https://rpc.testnet.chain.robinhood.com",
    stable: ["rUSDG", "0x7C902600cb5bf24225DF1a77b333D84e03C1F210"],
    tokens: {
      TSLA: "0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E",
      AMZN: "0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02",
    },
    feeds: {},
  },
};

const PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951";
const INIT = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438";
const Q96 = 2 ** 96;

const [netName, ...symbols] = process.argv.slice(2);
const net = NETS[netName];
if (!net) { console.error("usage: node scripts/find-routes.mjs mainnet|testnet SYMBOL..."); process.exit(2); }

let id = 0;
// The public RPC rate-limits bursts ("Too Many Requests"); back off and retry.
async function rpc(method, params) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(net.rpc, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) });
    const text = await r.text();
    const limited = r.status === 429 || /too many requests/i.test(text);
    if (limited && attempt < 8) { await new Promise(res => setTimeout(res, 500 * 2 ** attempt)); continue; }
    const j = JSON.parse(text);
    if (j.error) throw new Error(`${method}: ${j.error.message}`);
    return j.result;
  }
}
const extsload = async slot => BigInt(await rpc("eth_call", [{ to: PM, data: "0x1e2eaeaf" + slot.slice(2) }, "latest"]));

async function chainlinkUsd(feed) {
  if (!feed) return null;
  const r = await rpc("eth_call", [{ to: feed, data: "0xfeaf968c" }, "latest"]); // latestRoundData()
  return Number(BigInt("0x" + r.slice(66, 130))) / 1e8;
}

const [stableSym, stable] = net.stable;
console.log(`${netName}: hookless ${stableSym} pools, deepest first\n`);

for (const sym of symbols) {
  const token = net.tokens[sym];
  if (!token) { console.log(`${sym}: no address known for ${netName}\n`); continue; }
  const stableIs0 = BigInt(stable) < BigInt(token);
  const topics = [INIT, null, pad(stableIs0 ? stable : token).toLowerCase(), pad(stableIs0 ? token : stable).toLowerCase()];
  const logs = await rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "latest", address: PM, topics }]);

  const rows = [];
  let hooked = 0, empty = 0;
  for (const l of logs) {
    const d = l.data.slice(2);
    const fee = parseInt(d.slice(0, 64), 16);
    const spacing = parseInt(d.slice(64, 128), 16);
    const hooks = "0x" + d.slice(128 + 24, 192);
    if (BigInt(hooks) !== 0n) { hooked++; continue; }
    const poolId = l.topics[1];
    const state = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n]));
    const slot0 = await extsload(state);
    const L = await extsload("0x" + (BigInt(state) + 3n).toString(16).padStart(64, "0"));
    const sqrtP = Number(slot0 & ((1n << 160n) - 1n)) / Q96;
    if (L === 0n || sqrtP === 0) { empty++; continue; }
    // token1 per token0, raw; stable 6 dp, stock 18 dp
    const ratio = sqrtP * sqrtP;
    const usd = stableIs0 ? 1e12 / ratio : ratio * 1e12;
    const stableSide = stableIs0 ? Number(L) / sqrtP / 1e6 : Number(L) * sqrtP / 1e6;
    rows.push({ poolId, fee, spacing, usd, stableSide });
  }
  rows.sort((a, b) => b.stableSide - a.stableSide);
  const cl = await chainlinkUsd(net.feeds[sym]);
  console.log(`${sym}  ${logs.length} pools, ${hooked} with a hook, ${empty} hookless but empty, ${rows.length} usable` +
    (cl ? `   Chainlink $${cl.toFixed(2)}` : ""));
  for (const r of rows.slice(0, 5)) {
    const vs = cl ? `${((r.usd / cl - 1) * 100 >= 0 ? "+" : "")}${((r.usd / cl - 1) * 100).toFixed(2)}%` : "";
    console.log(`   ${r.stableSide.toLocaleString("en-US", { maximumFractionDigits: 0 }).padStart(12)} ${stableSyms(stableSym)} active` +
      `   $${r.usd.toFixed(2).padStart(9)} ${vs.padStart(9)}   fee ${(r.fee / 1e4).toFixed(2)}%  spacing ${r.spacing}   ${r.poolId}`);
  }
  console.log();
}

function stableSyms(s) { return s.padEnd(5); }
