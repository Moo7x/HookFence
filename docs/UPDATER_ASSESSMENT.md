# Assessment: a safer automated price updater for an always-available demo

**Status: assessment only. Nothing here is built.** The supervised version is
what gets published first; this must not delay it.

## The problem

The testnet feeds expire after an hour. Today they are republished by
`scripts/keep-testnet-feeds-fresh.sh` running on the developer's computer, signed
by the **deployer key — which also owns every Jayo contract**. Outside a session,
buying is paused (withdrawals are not). An always-available demo needs updates
without a person or a laptop, without putting the owner key online.

## What an attacker with the updater's power can do today

`DemoPriceFeed` bounds each update to 10%, but not how often updates happen. A
stolen updater key could walk a price 10% per transaction, a few seconds apart,
to anything — and the reference would then let the attacker's own trades pass a
floor computed from a price they chose. Any automation has to close that first.

## Options

| | How | Verdict |
|---|---|---|
| A. Status quo | keeper on a laptop, owner key | fine for supervised sessions; not always-on; owner key is online during sessions |
| B. Permissionless on-chain refresh | anyone calls `refresh()`, which reads pool spot | **reject**: one transaction can push the pool, refresh, and trade against the new reference |
| C. On-chain TWAP | time-weighted pool price | **not available**: these pools are hookless and record no observations; our own hooked pools would need equity we cannot mint |
| D. Scheduled keeper with a separate, constrained updater | Cloudflare Worker Cron Trigger (or any scheduler) signs with a dedicated **updater** key; owner key stays offline | **recommended**, with the contract changes below |

## Recommended design (D)

Contract changes — a `DemoPriceFeed` v2, and redeploying the three feeds:

1. **Minimum interval between updates** (e.g. 20 minutes). Removes the "walk it
   10% at a time" attack: the fastest possible drift becomes 10% per 20 minutes.
2. **Daily drift band**: an update may not move the price more than, say, 25%
   from the price 24 hours earlier without the owner. Caps what a compromised
   updater can do in a day.
3. **Separate roles, already supported**: `setUpdater(updaterKey)` from the owner;
   the owner key goes back offline.
4. Optionally one `FeedUpdater` contract that refreshes all three feeds in one
   transaction, so a partial update cannot leave feeds out of step.

Operations:

- A Cloudflare Worker with a Cron Trigger every 30 minutes (inside the one-hour
  heartbeat) reads both pools, skips anything outside the bounds, and sends one
  transaction. The updater key lives in the Worker as an encrypted secret, holds
  only a small amount of test ETH, and can do nothing but update the feeds within
  the on-chain bounds. It is a **separate** Worker from the Pages site; the site
  stays static and keyless.
- Cost: about 0.0000013 test ETH per refresh (measured), 48 a day ≈ 0.00006 ETH/day.
  The deployer's remaining 0.0096 ETH would fund roughly five months.
- Failure is visible, not silent: the site already shows each feed's age and
  switches to "Buying is unavailable" when one expires. The Worker's own failures
  would show in Cloudflare's logs; alerting is a small addition.

What it still cannot fix: the reference is copied from the pool, so an always-on
updater makes a manipulated pool *more* likely to be copied, not less — the
bounds limit how fast, not whether. That is inherent to a testnet with no
independent feed; on mainnet the reference is Chainlink's and none of this applies.

## Effort and order

About half a day: the feed v2 contract and its tests, redeploying three feeds and
repointing the policy (one owner transaction each), the Worker, and a runbook.
Only after the supervised site is published and has been tried by a real wallet.
