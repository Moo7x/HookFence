// Collect every Jayo testnet transaction's receipt from the PUBLIC RPC into one
// committed file, docs/evidence/testnet-<date>.json, so anyone can re-check each
// hash without trusting this repository.
//
//   node scripts/record-testnet-evidence.mjs <date> <phase:broadcast.json|phase:hash>...
//
// Each argument is "label=path/to/run-latest.json" (every transaction in that
// forge broadcast) or "label=0xhash" (a single transaction).

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const EXPLORER = "https://explorer.testnet.chain.robinhood.com";
const [date, ...specs] = process.argv.slice(2);
const read = p => JSON.parse(readFileSync(p, "utf8"));
// EVIDENCE_REPORT selects the deployment the evidence belongs to (default: version 1).
const deployment = read(process.env.EVIDENCE_REPORT || "contracts/reports/jayo-testnet.json");
const env = readFileSync("contracts/.env", "utf8");
const addr = name => env.split(/\r?\n/).find(l => l.startsWith(name + "="))?.split("=")[1]?.trim();
const wallets = { deployer: addr("DEPLOYER_ADDRESS"), Alice: addr("ALICE_ADDRESS"), Bob: addr("BOB_ADDRESS"), updater: addr("UPDATER_ADDRESS") };
if (process.env.OWNER_WALLET) wallets["project owner (own browser wallet)"] = process.env.OWNER_WALLET;
const who = Object.fromEntries(Object.entries(wallets).map(([k, v]) => [String(v).toLowerCase(), k]));

const steps = [];
for (const spec of specs) {
  const i = spec.indexOf("=");
  const phase = spec.slice(0, i), src = spec.slice(i + 1);
  if (/^0x[0-9a-fA-F]{64}$/.test(src)) { steps.push({ phase, what: phase, hash: src }); continue; }
  for (const t of read(src).transactions) {
    steps.push({ phase, what: t.transactionType === "CREATE" ? `deploy ${t.contractName}` : (t.function || "call").split("(")[0],
      hash: t.hash, created: t.contractAddress || undefined });
  }
}

async function receipt(hash) {
  for (let i = 0; i < 6; i++) {
    const r = await (await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getTransactionReceipt", params: [hash] }) })).json();
    if (r.result) return r.result;
    await new Promise(res => setTimeout(res, 4000));
  }
  return null;
}

let fee = 0n;
for (const s of steps) {
  const x = await receipt(s.hash);
  if (!x) { s.status = "MISSING"; continue; }
  s.status = x.status === "0x1" ? "success" : "reverted";
  s.block = Number(x.blockNumber);
  s.from = x.from;
  s.sender = who[x.from.toLowerCase()] || "other";
  s.gasUsed = Number(x.gasUsed);
  const f = BigInt(x.gasUsed) * BigInt(x.effectiveGasPrice);
  s.feeWei = f.toString();
  fee += f;
  s.explorer = `${EXPLORER}/tx/${s.hash}`;
}

mkdirSync("docs/evidence", { recursive: true });
const out = `docs/evidence/testnet-${date}.json`;
writeFileSync(out, JSON.stringify({
  network: "Robinhood Chain testnet", chainId: 46630, recordedOn: date, rpc: RPC,
  note: `Every entry is a receipt read from the public RPC. Re-check any hash: cast receipt <hash> --rpc-url ${RPC}`,
  wallets, contracts: deployment, totalFeesWei: fee.toString(), transactions: steps,
}, null, 2) + "\n");

const count = st => steps.filter(s => s.status === st).length;
console.log(`${out}: ${steps.length} transactions - ${count("success")} success, ${count("reverted")} reverted, ${count("MISSING")} missing`);
console.log(`total fees paid: ${(Number(fee) / 1e18).toFixed(8)} ETH`);
if (count("MISSING")) process.exitCode = 1;
