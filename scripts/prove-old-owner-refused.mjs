// Mine, on the public testnet, Alice's attempt to withdraw a basket she has
// already handed to Bob - so the refusal is a permanent receipt with status 0,
// not just an eth_call anyone would have to take our word for.
//
//   node scripts/prove-old-owner-refused.mjs <tokenId>
//
// The key is read from contracts/.env inside this process; it is never printed
// and never passed on a command line. The transaction is sent with an explicit
// gas limit because estimation (correctly) fails for a call that reverts.

import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const viemDir = join(REPO, "tools", "node_modules", "viem", "_esm");
const viem = await import(pathToFileURL(join(viemDir, "index.js")).href);
const { privateKeyToAccount } = await import(pathToFileURL(join(viemDir, "accounts", "index.js")).href);

const tokenId = BigInt(process.argv[2] ?? "");
const env = readFileSync(join(REPO, "contracts", ".env"), "utf8");
const key = env.split(/\r?\n/).find(l => l.startsWith("ALICE_PRIVATE_KEY="))?.split("=")[1]?.trim();
if (!/^0x[0-9a-fA-F]{64}$/.test(key || "")) throw new Error("ALICE_PRIVATE_KEY missing from contracts/.env");
const d = JSON.parse(readFileSync(join(REPO, "contracts", "reports", "jayo-testnet.json"), "utf8"));

const chain = { id: 46630, name: d.network, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [d.rpcUrl] } } };
const alice = privateKeyToAccount(key);
const pub = viem.createPublicClient({ chain, transport: viem.http(d.rpcUrl) });
const wallet = viem.createWalletClient({ account: alice, chain, transport: viem.http(d.rpcUrl) });
const abi = [
  { type: "function", name: "redeem", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
  { type: "error", name: "NotPositionOwner", inputs: [{ type: "uint256" }, { type: "address" }] },
];

const owner = await pub.readContract({ address: d.basket, abi, functionName: "ownerOf", args: [tokenId] });
if (owner.toLowerCase() === alice.address.toLowerCase()) throw new Error("Alice still owns it; nothing to prove");
console.log(`basket #${tokenId} is owned by ${owner}; Alice is ${alice.address}`);

// What the chain will say, decoded, before paying for it.
try {
  await pub.simulateContract({ address: d.basket, abi, functionName: "redeem", args: [tokenId], account: alice });
  throw new Error("the call would succeed - refusing to send");
} catch (e) {
  const name = e?.cause?.data?.errorName ?? e?.cause?.cause?.data?.errorName;
  const args = e?.cause?.data?.args ?? e?.cause?.cause?.data?.args;
  if (name !== "NotPositionOwner") throw e;
  console.log(`simulated: ${name}(${args.join(", ")})`);
}

const hash = await wallet.writeContract({ address: d.basket, abi, functionName: "redeem", args: [tokenId], gas: 150_000n });
const receipt = await pub.waitForTransactionReceipt({ hash });
console.log(`sent by Alice: ${hash}`);
console.log(`receipt status: ${receipt.status}  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);
console.log(`${d.explorer}/tx/${hash}`);
if (receipt.status !== "reverted") process.exitCode = 1;
