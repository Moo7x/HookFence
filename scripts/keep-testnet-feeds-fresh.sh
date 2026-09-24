#!/usr/bin/env bash
# Keep the Jayo testnet demo feeds inside their one-hour heartbeat while a demo
# session is open. Refreshes immediately, then every 40 minutes, until Ctrl-C.
#
#   ./scripts/keep-testnet-feeds-fresh.sh          loop
#   ./scripts/keep-testnet-feeds-fresh.sh --once   refresh once and exit
#
# Each refresh is three transactions signed by the deployer key in
# contracts/.env (the only address the feeds accept). When you stop this, the
# feeds age out after an hour and buying is refused - the safe resting state.
# Withdrawals need no price and keep working.
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
cd "$(dirname "$0")/../contracts"

[ -f .env ] || { echo "contracts/.env missing - run ./scripts/new-testnet-wallet.sh first"; exit 1; }
[ -f reports/jayo-testnet.json ] || { echo "no testnet deployment recorded in contracts/reports/jayo-testnet.json"; exit 1; }

refresh() {
  echo "[$(date -u +%H:%M:%SZ)] refreshing testnet feeds"
  forge script script/RefreshTestnetFeeds.s.sol \
    --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --slow 2>&1 \
    | grep -E "refreshed|SKIPPED|previous|pool now|age before|stale|ONCHAIN|Error" || true
}

refresh
[ "${1:-}" = "--once" ] && exit 0
while sleep 2400; do refresh; done
