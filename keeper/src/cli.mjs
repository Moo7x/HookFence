// Run the keeper's decisions against the live testnet WITHOUT sending anything.
//
//   node keeper/src/cli.mjs            reads contracts/reports/jayo-testnet-v2.json
//
// Holds no key and cannot publish. Sending from this machine is
// scripts/keep-testnet-feeds-fresh.sh; sending on a schedule is the Worker.

import { readFileSync } from "node:fs";
import { createPublicClient, http } from "viem";
import { refreshAll } from "./refresh.mjs";

const report = JSON.parse(readFileSync(new URL("../../contracts/reports/jayo-testnet-v2.json", import.meta.url), "utf8"));
const pub = createPublicClient({ transport: http(report.rpcUrl) });
await refreshAll({
  pub,
  wallet: null,
  cfg: {
    poolManager: report.poolManager,
    usdg: report.usdg,
    feeds: [
      { label: "TSLA", feed: report.tslaFeed, stock: report.tsla },
      { label: "AMZN", feed: report.amznFeed, stock: report.amzn },
      { label: "rUSDG", feed: report.usdgFeed, stock: null },
    ],
  },
});
