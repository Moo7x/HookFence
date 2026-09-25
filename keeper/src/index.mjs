// Jayo testnet keeper: a Cloudflare Worker that republishes the testnet demo
// price feeds on a schedule, so buying on https://jayo-testnet.pages.dev works
// while nobody's computer is on.
//
// AUTHORITY. It signs with UPDATER_KEY, a dedicated key stored as an encrypted
// Worker secret. On chain that key can do one thing: call setAnswer on the three
// DemoPriceFeed (version 2) contracts, which themselves refuse more than one
// update per 15 minutes, any step over 10% and more than 25% of movement a day.
// It owns nothing, holds a little test ETH for gas, and the deployer (owner) key
// never leaves the operator's machine. If this key leaked, the worst case is a
// testnet reference price walked 25% in a day, visibly, until the owner calls
// setUpdater with a new address.
//
// WHAT IT PUBLISHES is each pool's own current price. That is what the testnet
// reference has always been (Chainlink publishes no feeds on this testnet); the
// site says so. Independence from the pools is demonstrated only on the mainnet
// fork. No HTTP surface: the fetch handler answers 404.

import { createPublicClient, createWalletClient, http, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { refreshAll } from "./refresh.mjs";

function config(env) {
  return {
    poolManager: env.POOL_MANAGER,
    usdg: env.RUSDG,
    feeds: [
      { label: "TSLA", feed: env.TSLA_FEED, stock: env.TSLA },
      { label: "AMZN", feed: env.AMZN_FEED, stock: env.AMZN },
      { label: "rUSDG", feed: env.RUSDG_FEED, stock: null },
    ],
  };
}

export default {
  async scheduled(_event, env, ctx) {
    const chain = defineChain({
      id: Number(env.CHAIN_ID), name: "Robinhood Chain testnet",
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [env.RPC_URL] } },
    });
    const pub = createPublicClient({ chain, transport: http(env.RPC_URL) });
    if (!env.UPDATER_KEY) {
      console.log(JSON.stringify({ error: "UPDATER_KEY secret is not set; nothing was sent" }));
      ctx.waitUntil(refreshAll({ pub, wallet: null, cfg: config(env) }));
      return;
    }
    const account = privateKeyToAccount(env.UPDATER_KEY);
    const wallet = createWalletClient({ chain, transport: http(env.RPC_URL), account });
    ctx.waitUntil(refreshAll({ pub, wallet, cfg: config(env) }));
  },

  async fetch() {
    return new Response("Not found", { status: 404 });
  },
};
