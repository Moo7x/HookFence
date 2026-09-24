// The only viem surface the page uses. Bundled into app/vendor/ by
// build-vendor.mjs so the page loads no code from a third-party origin at runtime.
export {
  createPublicClient, createWalletClient, http, custom,
  parseUnits, formatUnits, isAddress, getAddress,
} from 'viem';
export { privateKeyToAccount } from 'viem/accounts';
export { foundry } from 'viem/chains';
