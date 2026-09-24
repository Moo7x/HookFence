// Fetch receipts for Jayo's testnet transactions straight from the public RPC and
// print what the chain says happened. Forge's own "ONCHAIN EXECUTION COMPLETE"
// line is not evidence; a receipt with status 1 in a mined block is.
//
//   node scripts/verify-testnet-receipts.mjs --broadcast contracts/broadcast/DeployJayoTestnet.s.sol/46630/run-latest.json
//   node scripts/verify-testnet-receipts.mjs 0xabc... 0xdef...
//
// Exits non-zero if any receipt is missing or failed.

import { readFileSync } from "node:fs";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const EXPLORER = "https://explorer.testnet.chain.robinhood.com";

async function rpc(method, params) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const args = process.argv.slice(2);
let items = [];
if (args[0] === "--broadcast") {
  const run = JSON.parse(readFileSync(args[1], "utf8"));
  items = run.transactions.map(t => ({
    hash: t.hash,
    what: t.transactionType === "CREATE" ? `deploy ${t.contractName}` : (t.function || "call").split("(")[0],
    created: t.contractAddress,
  }));
} else {
  items = args.map(hash => ({ hash, what: "" }));
}

let bad = 0;
let gasTotal = 0n, feeTotal = 0n;
console.log("status  block       gasUsed     tx                                                                   what");
for (const it of items) {
  // The public RPC load-balances across nodes that can trail the tip by a few
  // seconds: a receipt for a transaction in the newest block has been observed
  // missing on one read and present on the next. Retry before calling it missing.
  let r = null;
  for (let attempt = 0; attempt < 6 && !r; attempt++) {
    if (attempt) await new Promise(res => setTimeout(res, 5000));
    r = await rpc("eth_getTransactionReceipt", [it.hash]);
  }
  if (!r) { bad++; console.log(`MISSING ${" ".repeat(30)} ${it.hash}  ${it.what}`); continue; }
  const ok = r.status === "0x1";
  if (!ok) bad++;
  const gas = BigInt(r.gasUsed), price = BigInt(r.effectiveGasPrice || "0x0");
  gasTotal += gas; feeTotal += gas * price;
  const created = r.contractAddress ? `  -> ${r.contractAddress}` : "";
  console.log(`${ok ? "ok    " : "FAILED"}  ${String(BigInt(r.blockNumber)).padEnd(11)} ${String(gas).padStart(9)}   ${it.hash}  ${it.what}${created}`);
}
console.log(`\n${items.length} receipts, ${bad} missing or failed`);
console.log(`total gasUsed ${gasTotal} (includes the L1 data component on this chain), fees paid ${(Number(feeTotal) / 1e18).toFixed(8)} ETH`);
if (items[0]) console.log(`explorer: ${EXPLORER}/tx/${items[0].hash}`);
process.exitCode = bad ? 1 : 0; // not process.exit(): on Windows it can abort while sockets close
