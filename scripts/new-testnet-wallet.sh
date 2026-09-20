#!/usr/bin/env bash
# Generate a DEDICATED throwaway testnet wallet and write the key to contracts/.env.
# The key never leaves this machine and .env is git-ignored.
set -euo pipefail

ENV_FILE="$(dirname "$0")/../contracts/.env"
[ -f "$ENV_FILE" ] || cp "$(dirname "$0")/../.env.example" "$ENV_FILE"

OUT=$(cast wallet new)
ADDR=$(echo "$OUT" | grep -i 'Address' | awk '{print $NF}')
KEY=$(echo "$OUT"  | grep -i 'Private key' | awk '{print $NF}')

# Replace the PRIVATE_KEY line in place.
if grep -q '^PRIVATE_KEY=' "$ENV_FILE"; then
  sed -i "s|^PRIVATE_KEY=.*|PRIVATE_KEY=$KEY|" "$ENV_FILE"
else
  echo "PRIVATE_KEY=$KEY" >> "$ENV_FILE"
fi

echo "Dedicated testnet wallet created."
echo "  Address : $ADDR"
echo "  Key     : written to contracts/.env (git-ignored) - do NOT paste it anywhere"
echo
echo "Next: fund it at https://faucet.testnet.chain.robinhood.com/"
echo "Then: cast balance $ADDR --rpc-url https://rpc.testnet.chain.robinhood.com"
