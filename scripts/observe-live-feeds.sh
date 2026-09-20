#!/usr/bin/env bash
# Observe live Chainlink feed freshness on Robinhood Chain mainnet (chainId 4663).
#
# No API key required - uses the public RPC. Read-only.
# Writes a timestamped JSON record to contracts/reports/live-feeds-<unix>.json
#
# Purpose: Stock Token feeds are documented as updating 24/5 ("following market
# hours") while the AMM pools trade 24/7. This script measures the actual gap.
set -euo pipefail

RPC="${ROBINHOOD_MAINNET_RPC:-https://rpc.mainnet.chain.robinhood.com}"
HEARTBEAT=86400   # documented for every feed below, per Chainlink's directory
NOW=$(date +%s)
OUT_DIR="$(dirname "$0")/../contracts/reports"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/live-feeds-$NOW.json"

# name|address|class
FEEDS=(
  "AAPL/USD|0x6B22A786bAa607d76728168703a39Ea9C99f2cD0|stock"
  "NVDA/USD|0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15|stock"
  "TSLA/USD|0x4A1166a659A55625345e9515b32adECea5547C38|stock"
  "SPY/USD|0x319724394D3A0e3669269846abE664Cd621f9f6A|stock"
  "MSFT/USD|0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E|stock"
  "USDG/USD|0x61B7e5650328764B076A108EFF5fa7282a1B9aD2|crypto"
  "ETH/USD|0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9|crypto"
)

echo "Observed at : $(date -u -d @"$NOW" '+%a %Y-%m-%d %H:%M:%S UTC')  (unix $NOW)"
echo "RPC         : $RPC"
echo "Heartbeat   : ${HEARTBEAT}s (24h) for all feeds listed"
echo
printf "%-12s %-8s %-12s %-20s %10s %8s  %s\n" "FEED" "CLASS" "PRICE" "updatedAt (UTC)" "AGE(s)" "AGE(h)" "STATUS"

echo "{" > "$OUT"
echo "  \"observedAt\": $NOW," >> "$OUT"
echo "  \"observedAtUtc\": \"$(date -u -d @"$NOW" '+%Y-%m-%dT%H:%M:%SZ')\"," >> "$OUT"
echo "  \"dayOfWeekUtc\": \"$(date -u -d @"$NOW" '+%A')\"," >> "$OUT"
echo "  \"chainId\": 4663," >> "$OUT"
echo "  \"heartbeatSeconds\": $HEARTBEAT," >> "$OUT"
echo "  \"feeds\": [" >> "$OUT"

FIRST=1
for ROW in "${FEEDS[@]}"; do
  NAME="${ROW%%|*}"; REST="${ROW#*|}"; ADDR="${REST%%|*}"; CLASS="${REST##*|}"

  DATA=$(cast call "$ADDR" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$RPC")
  ANS=$(echo "$DATA" | sed -n '2p' | awk '{print $1}')
  UPD=$(echo "$DATA" | sed -n '4p' | awk '{print $1}')
  AGE=$(( NOW - UPD ))
  HRS=$(awk "BEGIN{printf \"%.1f\", $AGE/3600}")
  USD=$(awk "BEGIN{printf \"%.2f\", $ANS/100000000}")

  if [ "$AGE" -gt "$HEARTBEAT" ]; then STATUS="STALE"; else STATUS="fresh"; fi

  printf "%-12s %-8s %-12s %-20s %10s %8s  %s\n" \
    "$NAME" "$CLASS" "\$$USD" "$(date -u -d @"$UPD" '+%a %b %d %H:%M')" "$AGE" "$HRS" "$STATUS"

  [ $FIRST -eq 0 ] && echo "    ," >> "$OUT"
  FIRST=0
  cat >> "$OUT" <<JSON
    {
      "name": "$NAME", "class": "$CLASS", "proxy": "$ADDR",
      "answer": $ANS, "priceUsd": $USD,
      "updatedAt": $UPD, "ageSeconds": $AGE, "ageHours": $HRS,
      "exceedsHeartbeat": $( [ "$AGE" -gt "$HEARTBEAT" ] && echo true || echo false )
    }
JSON
done

echo "  ]" >> "$OUT"
echo "}" >> "$OUT"

echo
echo "Record written to: $OUT"
