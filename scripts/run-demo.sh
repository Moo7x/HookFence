#!/usr/bin/env bash
# One command to run the Jayo demo locally.
#   ./scripts/run-demo.sh
# Then open http://127.0.0.1:5173
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "starting anvil..."
pkill -f "anvil --silent --port 8545" 2>/dev/null || true
sleep 1
(anvil --silent --port 8545 >/dev/null 2>&1 &)
sleep 4

echo "deploying Jayo (ALL ASSETS ARE MOCKS)..."
cd "$ROOT/contracts"
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployJayoLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --skip-simulation 2>&1 \
  | grep -E "basket|gateway|policy|usdg|aapl|nvda|SUCCESSFUL"

echo ""
echo "starting the interface..."
cd "$ROOT"
pkill -f "node app/serve.mjs" 2>/dev/null || true
(node app/serve.mjs >/dev/null 2>&1 &)
sleep 2
echo ""
echo "  Jayo demo ready:  http://127.0.0.1:5173"
