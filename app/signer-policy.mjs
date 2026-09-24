// What the local test signer is allowed to sign, decided by DECODING the call.
//
// The first version checked only the destination: any calldata to the basket or
// to the stablecoin was signed. That included stablecoin.approve(attacker, max),
// basket.transferFrom(...) to anyone, and every owner-only admin function on the
// basket for whichever key the signer held. This module replaces that with an
// allowlist of exact functions, each with its own argument rules, and requires
// the calldata to be the canonical encoding of what was decoded, so nothing can
// ride along in trailing bytes.
//
// It is pure: give it a transaction request and the deployment context, get back
// { ok: true, account } or { ok: false, reason }. app/signer.test.mjs drives it
// both directly and through the running server.

import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";

const REPO = fileURLToPath(new URL("..", import.meta.url));
const { decodeFunctionData, encodeFunctionData, getAddress } =
  await import(pathToFileURL(join(REPO, "tools", "node_modules", "viem", "_esm", "index.js")).href);

// Only these functions exist as far as the signer is concerned. Anything else,
// including every admin function and every other ERC-20 / ERC-721 entry point,
// fails to decode and is refused.
const STABLECOIN_ABI = [
  { type: "function", name: "approve", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }] },
];
const BASKET_ABI = [
  { type: "function", name: "create", inputs: [
    { name: "allocation", type: "tuple[]", components: [{ name: "asset", type: "address" }, { name: "weightBps", type: "uint16" }] },
    { name: "usdgIn", type: "uint256" }, { name: "deadline", type: "uint256" }] },
  { type: "function", name: "copyAllocation", inputs: [
    { name: "sourceTokenId", type: "uint256" }, { name: "usdgIn", type: "uint256" }, { name: "deadline", type: "uint256" }] },
  { type: "function", name: "redeem", inputs: [{ name: "tokenId", type: "uint256" }] },
  { type: "function", name: "redeemAsset", inputs: [{ name: "tokenId", type: "uint256" }, { name: "asset", type: "address" }] },
  { type: "function", name: "redeemFraction", inputs: [{ name: "tokenId", type: "uint256" }, { name: "bps", type: "uint16" }] },
  { type: "function", name: "safeTransferFrom", inputs: [
    { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "tokenId", type: "uint256" }] },
];

export const LIMITS = {
  maxSpend: 100_000000n,   // 100 rUSDG per create/copy: a hijacked page cannot drain the wallet in one call
  maxGas: 2_000_000n,      // create measured 917,294 and copy 821,487 on a testnet fork
  maxLegs: 8,              // the basket's own MAX_LEGS
};

const lower = a => String(a).toLowerCase();
const refuse = reason => ({ ok: false, reason });

/**
 * @param tx   eth_sendTransaction params[0] as the page sent it
 * @param ctx  { chainId, basket, usdg, accounts: [address...], protected: [address...] }
 */
export function vetTransaction(tx, ctx) {
  if (!tx || typeof tx !== "object") return refuse("no transaction");
  if (!tx.to) return refuse("contract creation is never signed here");
  if (!tx.from) return refuse("the page must say which account is sending");

  const account = ctx.accounts.find(a => lower(a) === lower(tx.from));
  if (!account) return refuse(`${tx.from} is not one of this signer's accounts`);

  if (tx.value !== undefined && tx.value !== null && BigInt(tx.value) !== 0n) return refuse("will not send value");
  if (tx.chainId !== undefined && tx.chainId !== null && Number(tx.chainId) !== ctx.chainId) return refuse("wrong chain");
  if (tx.gas !== undefined && tx.gas !== null && BigInt(tx.gas) > LIMITS.maxGas) return refuse(`gas limit above ${LIMITS.maxGas}`);

  const data = lower(tx.data || tx.input || "0x");
  if (!/^0x[0-9a-f]*$/.test(data) || data.length < 10) return refuse("calldata is not a function call");

  const to = lower(tx.to);
  let abi, target;
  if (to === lower(ctx.usdg)) { abi = STABLECOIN_ABI; target = "stablecoin"; }
  else if (to === lower(ctx.basket)) { abi = BASKET_ABI; target = "basket"; }
  else return refuse(`will not sign a call to ${tx.to}`);

  let decoded;
  try {
    decoded = decodeFunctionData({ abi, data });
  } catch {
    return refuse(`that function is not allowed on the ${target}`);
  }
  // Canonical encoding only: rejects trailing bytes and non-standard padding that
  // decode leniently but could mean something else to the contract.
  if (lower(encodeFunctionData({ abi, functionName: decoded.functionName, args: decoded.args })) !== data) {
    return refuse("calldata is not the canonical encoding of an allowed call");
  }

  const [a0, a1, a2] = decoded.args;
  const protectedSet = new Set([ctx.basket, ctx.usdg, ...(ctx.protected || [])].map(lower));
  switch (`${target}.${decoded.functionName}`) {
    case "stablecoin.approve":
      if (lower(a0) !== lower(ctx.basket)) return refuse("the stablecoin may only be approved to the basket contract");
      return { ok: true, account, what: "approve basket" };

    case "basket.create":
      if (a0.length === 0 || a0.length > LIMITS.maxLegs) return refuse("allocation must have 1 to 8 legs");
      if (a1 > LIMITS.maxSpend) return refuse(`spends more than the test signer's limit of ${LIMITS.maxSpend}`);
      return { ok: true, account, what: `create ${a1}` };

    case "basket.copyAllocation":
      if (a1 > LIMITS.maxSpend) return refuse(`spends more than the test signer's limit of ${LIMITS.maxSpend}`);
      return { ok: true, account, what: `copy #${a0} with ${a1}` };

    case "basket.redeem":
    case "basket.redeemAsset":
    case "basket.redeemFraction":
      return { ok: true, account, what: `${decoded.functionName} #${a0}` };

    case "basket.safeTransferFrom":
      if (lower(a0) !== lower(account)) return refuse("can only hand over a basket from the sending account");
      if (/^0x0{40}$/.test(lower(a1))) return refuse("will not transfer to the zero address");
      if (protectedSet.has(lower(a1))) return refuse("will not transfer a basket to one of Jayo's own contracts");
      return { ok: true, account, what: `hand #${a2} to ${getAddress(a1)}` };
  }
  return refuse("not an allowed call");
}
