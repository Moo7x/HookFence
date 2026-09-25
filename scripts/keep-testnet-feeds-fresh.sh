#!/usr/bin/env bash
# Keep the Jayo testnet demo feeds inside their one-hour heartbeat from this
# machine. Refreshes immediately, then every 20 minutes, until Ctrl-C.
#
# The public site does not depend on this: a scheduled Cloudflare Worker
# (keeper/) does the same job while this computer is off. This script is the
# fallback, and the way to refresh by hand.
#
#   ./scripts/keep-testnet-feeds-fresh.sh          loop
#   ./scripts/keep-testnet-feeds-fresh.sh --once   refresh once and exit
#
# Each refresh is up to three transactions signed by the dedicated UPDATER key in
# contracts/.env - never the deployer's. The version-2 feeds accept at most one
# update per 15 minutes, no step over 10% and no more than 25% of movement a day,
# so a refresh can print WAITING or SKIPPED rather than send. When nothing
# refreshes, the feeds age out after an hour and buying is refused - the safe
# resting state. Withdrawals need no price and keep working.
#
# FAILURES ARE LOUD. An earlier version ended its pipeline in `grep ... || true`,
# so a failed refresh printed nothing and exited 0 while the feeds went stale.
# Now forge's own exit status decides: a failed run prints FAILED with the tail
# of the log, `--once` exits non-zero, and the loop keeps a count of consecutive
# failures and says how long the feeds have left.
set -uo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
cd "$(dirname "$0")/../contracts"

[ -f .env ] || { echo "contracts/.env missing - run ./scripts/new-testnet-wallet.sh first"; exit 1; }
[ -f reports/jayo-testnet-v2.json ] || { echo "no version-2 deployment recorded in contracts/reports/jayo-testnet-v2.json"; exit 1; }
grep -qE "^UPDATER_PRIVATE_KEY=0x" .env || { echo "no updater key - run ./scripts/new-testnet-wallet.sh --role updater first"; exit 1; }

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
FAILS=0

refresh() {
  echo "[$(date -u +%H:%M:%SZ)] refreshing testnet feeds"
  if forge script script/RefreshTestnetFeeds.s.sol \
       --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --slow >"$LOG" 2>&1; then
    grep -E "refreshed|SKIPPED|WAITING|previous|pool now|anchor|age before|stale" "$LOG" || true
    if grep -q "SKIPPED" "$LOG"; then
      echo "  WARNING: at least one feed was not refreshed (step or daily bound). It will expire; buying for that asset will stop."
    fi
    FAILS=0
    return 0
  fi
  FAILS=$((FAILS + 1))
  echo "  FAILED (consecutive failures: $FAILS). Last lines of the forge log:"
  tail -n 15 "$LOG" | sed 's/^/    /'
  echo "  The feeds keep their last update; buying stops when it is an hour old."
  return 1
}

if [ "${1:-}" = "--once" ]; then refresh; exit $?; fi
refresh || true
while sleep 1200; do refresh || true; done
