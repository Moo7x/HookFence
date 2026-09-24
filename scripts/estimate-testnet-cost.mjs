// What a Jayo testnet demo actually costs in test ETH, per transaction.
//
// Two steps. First replay every transaction the demo will send - deployment, the
// whole journey, one feed refresh - on a LOCAL fork of the testnet, so each gets
// a real receipt. Nothing is broadcast to the public chain:
//
//   anvil --fork-url https://rpc.testnet.chain.robinhood.com --port 8546
//   cast rpc anvil_setBalance <sim address> 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:8546
//   cd contracts && PRIVATE_KEY=<sim key, no code, no history> forge script //     script/SimulateTestnetDemo.s.sol --rpc-url http://127.0.0.1:8546 --broadcast --slow
//
// Then price them:
//
//   node ../scripts/estimate-testnet-cost.mjs
//
// WHY BOTH HALVES. Robinhood Chain is an Arbitrum Orbit chain: every transaction
// pays for its L2 execution AND for posting its calldata to the parent chain.
// A local EVM, anvil included, sees only the first. The L2 part comes from the
// fork's receipts; the L1 part comes from the live chain's own NodeInterface
// precompile, asked about each transaction's exact calldata.
//
// The first figure quoted for this deployment (0.00028 ETH) had both problems:
// no L1 component, and forge's dry-run estimates, which price every call into a
// contract deployed earlier in the same script as an empty call (it put `create`,
// two real swaps, at 38,900 gas; its receipt says 917,294).
//
// No dependencies: plain fetch against the public RPC.

import { readFileSync } from "node:fs";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const NODE_INTERFACE = "0x00000000000000000000000000000000000000c8";
const SEL_L1 = "0x77d488a2"; // gasEstimateL1Component(address,bool,bytes)
const run = JSON.parse(readFileSync("broadcast/SimulateTestnetDemo.s.sol/46630/run-latest.json", "utf8"));
if (!run.receipts || run.receipts.length !== run.transactions.length) {
  throw new Error("no receipts: replay SimulateTestnetDemo on a local fork first (see the header)");
}

async function rpc(method, params) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const word = hex => hex.replace(/^0x/, "").padStart(64, "0");
function encodeL1Call(to, creation, data) {
  const body = (data || "0x").replace(/^0x/, "");
  const len = body.length / 2;
  const padded = body.padEnd(Math.ceil(body.length / 64) * 64, "0");
  return SEL_L1 + word(to || "0x0") + word(creation ? "1" : "0") + word((96).toString(16)) + word(len.toString(16)) + padded;
}

function phaseOf(tx) {
  const fn = tx.function || "";
  if (tx.transactionType === "CREATE" || /^(setQuoteAsset|setStockToken|setGateway|setAdapter|setRoute|setAssetRoute|mint)\(/.test(fn)) return "deploy";
  if (/^setAnswer\(/.test(fn)) return "refresh";
  return "journey";
}

const gasPrice = BigInt(await rpc("eth_gasPrice", []));
const rows = [];
for (const [i, tx] of run.transactions.entries()) {
  const t = tx.transaction;
  const creation = tx.transactionType === "CREATE";
  const input = t.input || t.data || "0x";
  const res = await rpc("eth_call", [{ to: NODE_INTERFACE, data: encodeL1Call(creation ? null : t.to, creation, input) }, "latest"]);
  const l1Gas = BigInt("0x" + res.slice(2, 66));
  const l2Gas = BigInt(run.receipts[i].gasUsed);
  rows.push({
    phase: phaseOf(tx),
    what: creation ? `deploy ${tx.contractName}` : (tx.function || "call").split("(")[0],
    bytes: (input.length - 2) / 2, l2Gas, l1Gas,
  });
}

const eth = wei => (Number(wei) / 1e18).toFixed(7);
console.log(`gas price now: ${Number(gasPrice) / 1e9} gwei\n`);
console.log("phase     transaction                         calldata   L2 exec gas   L1 data gas");
for (const r of rows) {
  console.log(`${r.phase.padEnd(9)} ${r.what.padEnd(35)} ${String(r.bytes).padStart(8)}B ${String(r.l2Gas).padStart(13)} ${String(r.l1Gas).padStart(13)}`);
}

const sum = (ph, k) => rows.filter(r => r.phase === ph).reduce((a, r) => a + r[k], 0n);
console.log("\nper phase, at the current gas price:");
const totals = {};
for (const ph of ["deploy", "journey", "refresh"]) {
  const l2 = sum(ph, "l2Gas"), l1 = sum(ph, "l1Gas");
  totals[ph] = (l2 + l1) * gasPrice;
  const n = rows.filter(r => r.phase === ph).length;
  console.log(`  ${ph.padEnd(8)} ${String(n).padStart(2)} tx   L2 ${String(l2).padStart(9)}  +  L1 ${String(l1).padStart(9)}  =  ${eth(totals[ph])} ETH` +
    `   (L1 share ${(Number(l1) * 100 / Number(l1 + l2)).toFixed(0)}%)`);
}
console.log(`\n  L2-only figure (what a local simulation reports): ${eth((sum("deploy","l2Gas") + sum("journey","l2Gas") + sum("refresh","l2Gas")) * gasPrice)} ETH`);
console.log(`  with the L1 component:                            ${eth(totals.deploy + totals.journey + totals.refresh)} ETH`);

// A demo plan, stated as its parts so it can be re-derived.
const plan = { deploy: 1n, journey: 5n, refresh: 30n };
const need = totals.deploy * plan.deploy + totals.journey * plan.journey + totals.refresh * plan.refresh;
console.log(`\nplan: 1 deployment + ${plan.journey} full journeys (retakes) + ${plan.refresh} feed refreshes (~20 hours of live demo at one per 40 min)`);
console.log(`  at today's gas price:         ${eth(need)} ETH`);
console.log(`  budget, 3x for fee spikes:    ${eth(need * 3n)} ETH`);
