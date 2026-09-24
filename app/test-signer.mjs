// The local TEST signer: two demo user wallets that sign only the decoded user
// journey. Used by `node app/serve.mjs --testnet-signer` and by
// `node scripts/serve-site.mjs --test-wallet` (which stands it in for a browser
// wallet while verifying the hosted build).
//
// NEVER part of the hosted site. scripts/build-site.mjs refuses to produce a
// build that references it.
//
// What makes it tolerable:
//   - It holds only ALICE_PRIVATE_KEY and BOB_PRIVATE_KEY. It refuses to start
//     if either equals the deployer's key, or each other, so no owner-only
//     function on any Jayo contract can be signed through it.
//   - Every eth_sendTransaction is decoded and checked by signer-policy.mjs.
//   - Keys never leave this process and are never logged.

import { readFile } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const APP_DIR = fileURLToPath(new URL(".", import.meta.url));

function envValue(env, name) {
  const line = env.split(/\r?\n/).find(l => l.startsWith(name + "="));
  return line ? line.slice(name.length + 1).trim() : "";
}

const READ_METHODS = new Set([
  "eth_chainId", "eth_blockNumber", "eth_call", "eth_estimateGas", "eth_getBalance",
  "eth_getTransactionCount", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory",
  "eth_getBlockByNumber", "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getCode",
]);

/**
 * @param envPath       contracts/.env (or a test fixture)
 * @param manifest      a SANITISED deployment manifest for chain 46630
 * @returns { accounts, handle(body) } - or throws with a reason to refuse to start
 */
export async function createTestSigner({ envPath, manifest: m }) {
  const env = await readFile(envPath, "utf8").catch(() => "");
  const keys = [["Alice", envValue(env, "ALICE_PRIVATE_KEY")], ["Bob", envValue(env, "BOB_PRIVATE_KEY")]];
  const deployerKey = envValue(env, "PRIVATE_KEY");
  for (const [who, k] of keys) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(k)) {
      throw new Error(`no ${who.toUpperCase()}_PRIVATE_KEY in contracts/.env. Run ./scripts/new-testnet-wallet.sh --role ${who.toLowerCase()}.`);
    }
    if (deployerKey && k.toLowerCase() === deployerKey.toLowerCase()) {
      throw new Error(`${who}'s key is the deployer's key. The signer never holds an admin key.`);
    }
  }
  if (keys[0][1].toLowerCase() === keys[1][1].toLowerCase()) {
    throw new Error("Alice and Bob must be two different wallets.");
  }
  if (m.chainId !== 46630) throw new Error(`the deployment manifest is for chain ${m.chainId}, not 46630.`);

  const viemDir = join(REPO, "tools", "node_modules", "viem", "_esm");
  const viem = await import(pathToFileURL(join(viemDir, "index.js")).href);
  const { privateKeyToAccount } = await import(pathToFileURL(join(viemDir, "accounts", "index.js")).href);
  const { vetTransaction } = await import(pathToFileURL(join(APP_DIR, "signer-policy.mjs")).href);

  const chain = {
    id: 46630, name: m.network,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [m.rpcUrl] } },
  };
  const wallets = new Map();
  for (const [, k] of keys) {
    const account = privateKeyToAccount(k);
    wallets.set(account.address.toLowerCase(), viem.createWalletClient({ account, chain, transport: viem.http(m.rpcUrl) }));
  }
  const accounts = keys.map(([, k]) => privateKeyToAccount(k).address);
  const ctx = {
    chainId: 46630, basket: m.basket, usdg: m.usdg, accounts,
    protected: [m.gateway, m.policy, m.adapter, m.poolManager, ...(m.stocks || [])].filter(Boolean),
  };

  async function handle(body) {
    const { id, method, params = [] } = body;
    const ok = result => ({ jsonrpc: "2.0", id, result });
    const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

    if (method === "eth_accounts" || method === "eth_requestAccounts") return ok(accounts);
    if (method === "eth_chainId") return ok("0xb626");

    if (method === "eth_sendTransaction") {
      const tx = params[0] || {};
      const verdict = vetTransaction(tx, ctx);
      if (!verdict.ok) {
        console.log(`REFUSED ${verdict.reason}`);
        return fail(4100, `test signer refused: ${verdict.reason}`);
      }
      // Only `to`, `data` and a bounded `gas` are taken from the page. Nonce and
      // fees are filled from the chain; anything else the page sent is ignored.
      const wallet = wallets.get(verdict.account.toLowerCase());
      const hash = await wallet.sendTransaction({ to: tx.to, data: tx.data, gas: tx.gas ? BigInt(tx.gas) : undefined });
      console.log(`signed  ${verdict.what}  from=${verdict.account}  tx=${hash}`);
      return ok(hash);
    }

    if (READ_METHODS.has(method)) {
      const r = await fetch(m.rpcUrl, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
      });
      return await r.json();
    }
    console.log(`UNSUPPORTED method ${String(method).slice(0, 60)}`);
    return fail(4200, `method ${method} is not supported by the test signer`);
  }

  return { accounts, handle };
}
