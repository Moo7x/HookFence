// The viem surface the HOSTED site uses: no account or key handling at all
// (the visitor's wallet signs), and no local chain definitions.
export {
  createPublicClient, createWalletClient, http, custom,
  parseUnits, formatUnits, isAddress, getAddress,
} from 'viem';
