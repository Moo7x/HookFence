// The test signer, switched ON, must sign the user journey and nothing else.
//
//   node --test app/signer.test.mjs        (needs: cd tools && npm install)
//
// Two layers:
//   1. app/signer-policy.mjs called directly with decoded-and-re-encoded calls.
//   2. `node app/serve.mjs --testnet-signer` started for real, pointed at a
//      throwaway manifest and a FAKE RPC that records every method it receives.
//      A refused request must produce an error AND leave no eth_sendRawTransaction
//      at the fake RPC - i.e. nothing was signed and sent. An allowed one must
//      arrive there as a signed raw transaction.
//
// The keys below are anvil's published development keys. They hold nothing on
// any network and exist here only to exercise signing against a fake RPC.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const viem = await import(pathToFileURL(join(REPO, "tools", "node_modules", "viem", "_esm", "index.js")).href);
const { privateKeyToAccount } = await import(pathToFileURL(join(REPO, "tools", "node_modules", "viem", "_esm", "accounts", "index.js")).href);
const { vetTransaction, LIMITS } = await import("./signer-policy.mjs");

const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const ALICE_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const BOB_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
const ALICE = privateKeyToAccount(ALICE_KEY).address;
const BOB = privateKeyToAccount(BOB_KEY).address;
const DEPLOYER = privateKeyToAccount(DEPLOYER_KEY).address;

const BASKET = "0x" + "b".repeat(40);
const USDG = "0x" + "c".repeat(40);
const GATEWAY = "0x" + "d".repeat(40);
const TSLA = "0x" + "e".repeat(40);
const ATTACKER = "0x" + "a".repeat(40);

const CTX = { chainId: 46630, basket: BASKET, usdg: USDG, accounts: [ALICE, BOB], protected: [GATEWAY, TSLA] };

// Every function a hijacked page might try, with the real ABI shapes.
const ABI = [
  { type: "function", name: "approve", inputs: [{ type: "address" }, { type: "uint256" }] },
  { type: "function", name: "transfer", inputs: [{ type: "address" }, { type: "uint256" }] },
  { type: "function", name: "transferFrom", inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }] },
  { type: "function", name: "increaseAllowance", inputs: [{ type: "address" }, { type: "uint256" }] },
  { type: "function", name: "mint", inputs: [{ type: "address" }, { type: "uint256" }] },
  { type: "function", name: "setApprovalForAll", inputs: [{ type: "address" }, { type: "bool" }] },
  { type: "function", name: "setManager", inputs: [{ type: "uint256" }, { type: "address" }] },
  { type: "function", name: "transferOwnership", inputs: [{ type: "address" }] },
  { type: "function", name: "setMinLegInput", inputs: [{ type: "uint256" }] },
  { type: "function", name: "recoverSurplus", inputs: [{ type: "address" }, { type: "address" }] },
  { type: "function", name: "safeTransferFrom", inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }] },
  { type: "function", name: "safeTransferFrom", inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }, { type: "bytes" }] },
  { type: "function", name: "create", inputs: [
    { type: "tuple[]", components: [{ name: "asset", type: "address" }, { name: "weightBps", type: "uint16" }] },
    { type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "copyAllocation", inputs: [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "redeem", inputs: [{ type: "uint256" }] },
  { type: "function", name: "redeemAsset", inputs: [{ type: "uint256" }, { type: "address" }] },
  { type: "function", name: "redeemFraction", inputs: [{ type: "uint256" }, { type: "uint16" }] },
];
const enc = (name, args, arity) => {
  const abi = ABI.filter(f => f.name === name && (arity === undefined || f.inputs.length === arity));
  return viem.encodeFunctionData({ abi, functionName: name, args });
};
const alloc = [{ asset: TSLA, weightBps: 6000 }, { asset: "0x" + "f".repeat(40), weightBps: 4000 }];

const ALLOWED = {
  "approve the basket": { from: ALICE, to: USDG, data: enc("approve", [BASKET, 10n ** 30n]) },
  "create within the cap": { from: ALICE, to: BASKET, data: enc("create", [alloc, 20_000000n, 1n]) },
  "copy within the cap": { from: BOB, to: BASKET, data: enc("copyAllocation", [1n, 8_000000n, 1n]) },
  "redeem": { from: BOB, to: BASKET, data: enc("redeem", [1n]) },
  "redeem one asset": { from: ALICE, to: BASKET, data: enc("redeemAsset", [1n, TSLA]) },
  "redeem a fraction": { from: ALICE, to: BASKET, data: enc("redeemFraction", [1n, 5000]) },
  "hand over to Bob": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, BOB, 1n], 3) },
  "hand over to a stranger the user typed": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, ATTACKER, 1n], 3) },
};

const REFUSED = {
  "stablecoin approve to an arbitrary spender": { from: ALICE, to: USDG, data: enc("approve", [ATTACKER, 10n ** 30n]) },
  "stablecoin approve to the gateway": { from: ALICE, to: USDG, data: enc("approve", [GATEWAY, 1n]) },
  "stablecoin transfer": { from: ALICE, to: USDG, data: enc("transfer", [ATTACKER, 1n]) },
  "stablecoin transferFrom": { from: ALICE, to: USDG, data: enc("transferFrom", [BOB, ATTACKER, 1n]) },
  "stablecoin increaseAllowance": { from: ALICE, to: USDG, data: enc("increaseAllowance", [ATTACKER, 1n]) },
  "stablecoin mint": { from: ALICE, to: USDG, data: enc("mint", [ATTACKER, 1n]) },
  "basket NFT approve (same selector as ERC-20 approve)": { from: ALICE, to: BASKET, data: enc("approve", [ATTACKER, 1n]) },
  "basket setApprovalForAll": { from: ALICE, to: BASKET, data: enc("setApprovalForAll", [ATTACKER, true]) },
  "basket plain transferFrom": { from: ALICE, to: BASKET, data: enc("transferFrom", [ALICE, ATTACKER, 1n]) },
  "safeTransferFrom with data (4 args)": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, ATTACKER, 1n, "0x"], 4) },
  "safeTransferFrom from someone else": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [BOB, ATTACKER, 1n], 3) },
  "safeTransferFrom to the zero address": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, "0x" + "0".repeat(40), 1n], 3) },
  "safeTransferFrom to the basket itself": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, BASKET, 1n], 3) },
  "safeTransferFrom to the gateway": { from: ALICE, to: BASKET, data: enc("safeTransferFrom", [ALICE, GATEWAY, 1n], 3) },
  "basket setManager": { from: ALICE, to: BASKET, data: enc("setManager", [1n, ATTACKER]) },
  "basket transferOwnership (admin)": { from: ALICE, to: BASKET, data: enc("transferOwnership", [ATTACKER]) },
  "basket setMinLegInput (admin)": { from: ALICE, to: BASKET, data: enc("setMinLegInput", [0n]) },
  "basket recoverSurplus (admin)": { from: ALICE, to: BASKET, data: enc("recoverSurplus", [TSLA, ATTACKER]) },
  "create above the spend cap": { from: ALICE, to: BASKET, data: enc("create", [alloc, LIMITS.maxSpend + 1n, 1n]) },
  "copy above the spend cap": { from: ALICE, to: BASKET, data: enc("copyAllocation", [1n, LIMITS.maxSpend + 1n, 1n]) },
  "create with no legs": { from: ALICE, to: BASKET, data: enc("create", [[], 1n, 1n]) },
  "redeem with trailing bytes": { from: ALICE, to: BASKET, data: enc("redeem", [1n]) + "deadbeef" },
  "unknown selector": { from: ALICE, to: BASKET, data: "0x12345678" },
  "empty calldata": { from: ALICE, to: BASKET, data: "0x" },
  "a call to any other contract": { from: ALICE, to: GATEWAY, data: enc("redeem", [1n]) },
  "contract creation": { from: ALICE, data: "0x6080" },
  "sending value": { from: ALICE, to: BASKET, data: enc("redeem", [1n]), value: "0x1" },
  "the deployer as sender": { from: DEPLOYER, to: BASKET, data: enc("redeem", [1n]) },
  "no sender at all": { to: BASKET, data: enc("redeem", [1n]) },
  "a gas limit above the cap": { from: ALICE, to: BASKET, data: enc("redeem", [1n]), gas: "0x" + (LIMITS.maxGas + 1n).toString(16) },
  "the wrong chain": { from: ALICE, to: BASKET, data: enc("redeem", [1n]), chainId: "0x1" },
};

// --------------------------------------------------------------- layer 1 ---

for (const [name, tx] of Object.entries(ALLOWED)) {
  test(`policy allows: ${name}`, () => assert.equal(vetTransaction(tx, CTX).ok, true, JSON.stringify(vetTransaction(tx, CTX))));
}
for (const [name, tx] of Object.entries(REFUSED)) {
  test(`policy refuses: ${name}`, () => {
    const v = vetTransaction(tx, CTX);
    assert.equal(v.ok, false);
    assert.ok(v.reason && v.reason.length > 5);
  });
}

// --------------------------------------------------------------- layer 2 ---

const PORT = 5198;
const RPC_PORT = 5197;
let fakeRpc, child, token, dir;
const rpcCalls = [];

function startFakeRpc() {
  return new Promise(resolve => {
    fakeRpc = createServer(async (req, res) => {
      let body = "";
      for await (const c of req) body += c;
      const msgs = [].concat(JSON.parse(body));
      const answer = m => {
        rpcCalls.push(m.method);
        const r = {
          eth_chainId: "0xb626",
          eth_getTransactionCount: "0x0",
          eth_estimateGas: "0x30d40",
          eth_maxPriorityFeePerGas: "0x1",
          eth_gasPrice: "0x989680",
          eth_blockNumber: "0x10",
          eth_getBlockByNumber: {
            number: "0x10", hash: "0x" + "1".repeat(64), parentHash: "0x" + "2".repeat(64),
            timestamp: "0x66000000", baseFeePerGas: "0x989680", gasLimit: "0x1c9c380", gasUsed: "0x0",
            miner: "0x" + "0".repeat(40), transactions: [], difficulty: "0x0", extraData: "0x",
            logsBloom: "0x" + "0".repeat(512), nonce: "0x0000000000000000", sha3Uncles: "0x" + "3".repeat(64),
            size: "0x0", stateRoot: "0x" + "4".repeat(64), receiptsRoot: "0x" + "5".repeat(64),
            transactionsRoot: "0x" + "6".repeat(64), uncles: [], totalDifficulty: "0x0", mixHash: "0x" + "7".repeat(64),
          },
          eth_sendRawTransaction: "0x" + "9".repeat(64),
        }[m.method];
        return { jsonrpc: "2.0", id: m.id, result: r === undefined ? null : r };
      };
      const out = Array.isArray(JSON.parse(body)) ? msgs.map(answer) : answer(msgs[0]);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(out));
    }).listen(RPC_PORT, "127.0.0.1", resolve);
  });
}

before(async () => {
  await startFakeRpc();
  dir = mkdtempSync(join(tmpdir(), "jayo-signer-"));
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    chainId: 46630, network: "robinhood-chain-testnet", basket: BASKET, usdg: USDG, gateway: GATEWAY,
    stocks: [TSLA], rpcUrl: `http://127.0.0.1:${RPC_PORT}`, demoControls: false,
  }));
  writeFileSync(join(dir, ".env"),
    `PRIVATE_KEY=${DEPLOYER_KEY}\nALICE_PRIVATE_KEY=${ALICE_KEY}\nBOB_PRIVATE_KEY=${BOB_KEY}\n`);

  child = spawn(process.execPath, [join(REPO, "app", "serve.mjs"), "--testnet-signer"], {
    env: { ...process.env, JAYO_PORT: String(PORT), JAYO_MANIFEST_SRC: join(dir, "manifest.json"), JAYO_SIGNER_ENV: join(dir, ".env") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("server did not start: " + log)), 15000);
    child.stdout.on("data", d => { log += d; if (/running at/.test(log)) { clearTimeout(t); resolve(); } });
    child.stderr.on("data", d => { log += d; });
    child.on("exit", c => reject(new Error(`server exited ${c}: ${log}`)));
  });
  const page = await (await fetch(`http://127.0.0.1:${PORT}/`)).text();
  token = page.match(/name="jayo-signer-token" content="([0-9a-f]+)"/)[1];
});

after(async () => {
  child?.kill();
  await new Promise(r => fakeRpc.close(r));
  rmSync(dir, { recursive: true, force: true });
});

async function signerCall(method, params, { withToken = true, origin = `http://127.0.0.1:${PORT}` } = {}) {
  const headers = { "content-type": "application/json", origin };
  if (withToken) headers["x-jayo-signer-token"] = token;
  const r = await fetch(`http://127.0.0.1:${PORT}/signer`, { method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  return { status: r.status, json: r.status === 200 ? await r.json() : null };
}

test("server: the token is in the served page, and the manifest lists only user wallets", async () => {
  assert.match(token, /^[0-9a-f]{48}$/);
  const m = await (await fetch(`http://127.0.0.1:${PORT}/deployment.json`)).json();
  assert.deepEqual(m.localSigners, [ALICE, BOB]);
  assert.ok(!JSON.stringify(m).toLowerCase().includes(DEPLOYER.toLowerCase().slice(2)), "deployer is not a signer");
});

test("server: eth_accounts returns Alice and Bob, never the deployer", async () => {
  const r = await signerCall("eth_accounts", []);
  assert.deepEqual(r.json.result, [ALICE, BOB]);
});

test("server: no token, wrong token or foreign origin is refused before anything else", async () => {
  assert.equal((await signerCall("eth_accounts", [], { withToken: false })).status, 403);
  assert.equal((await signerCall("eth_accounts", [], { origin: "https://evil.example" })).status, 403);
  const bad = await fetch(`http://127.0.0.1:${PORT}/signer`, { method: "POST",
    headers: { "content-type": "application/json", origin: `http://127.0.0.1:${PORT}`, "x-jayo-signer-token": "0".repeat(48) },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_accounts", params: [] }) });
  assert.equal(bad.status, 403);
});

test("server: unknown JSON-RPC methods are refused", async () => {
  for (const m of ["eth_sign", "personal_sign", "eth_signTypedData_v4", "eth_signTransaction", "wallet_addEthereumChain"]) {
    const r = await signerCall(m, []);
    assert.ok(r.json.error, `${m} should be refused`);
  }
});

for (const [name, tx] of Object.entries(REFUSED)) {
  test(`server refuses and signs nothing: ${name}`, async () => {
    const before = rpcCalls.filter(m => m === "eth_sendRawTransaction").length;
    const r = await signerCall("eth_sendTransaction", [tx]);
    assert.equal(r.status, 200);
    assert.ok(r.json.error, "expected a JSON-RPC error");
    assert.match(r.json.error.message, /test signer refused/);
    assert.equal(rpcCalls.filter(m => m === "eth_sendRawTransaction").length, before, "nothing reached the chain");
  });
}

test("server: an allowed call is signed and broadcast", async () => {
  const before = rpcCalls.filter(m => m === "eth_sendRawTransaction").length;
  const r = await signerCall("eth_sendTransaction", [ALLOWED["approve the basket"]]);
  assert.equal(r.json.result, "0x" + "9".repeat(64), JSON.stringify(r.json));
  assert.equal(rpcCalls.filter(m => m === "eth_sendRawTransaction").length, before + 1);
});

test("server: Bob's calls are signed as Bob", async () => {
  const r = await signerCall("eth_sendTransaction", [ALLOWED["redeem"]]);
  assert.ok(r.json.result, JSON.stringify(r.json));
});
