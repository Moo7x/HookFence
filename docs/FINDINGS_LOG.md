# Findings log — what the chain actually says

Running record of measured facts and the ideas they killed. Every line is
reproducible from `scripts/`. Kept so we never re-litigate a dead idea.

## Measured facts (Robinhood Chain mainnet, chainId 4663, 2026-09-20)

| # | Finding | Script |
|---|---|---|
| 1 | Uniswap v4 very active: ~1,000 swaps/min, 837,000 pools created | `scan-pool-activity.mjs` |
| 2 | Stock Tokens trade against memecoins with sustained volume: NVDA/SI 849 swaps, musebook/META, CHONK/LLY, SCHIFFY/GLD | `scan-pool-activity.mjs` |
| 3 | USDG is a real quote asset; ETH/USDG, ROBIN/USDG, CASHCAT/USDG, AI/USDG all traded in 6/6 windows | `scan-pool-activity.mjs` |
| 4 | Verified launch-asset liquidity: ETH, GOOGL, NVDA + ROBIN, CASHCAT, AI. **SPY, AAPL, MSTR have NO sustained USDG liquidity** | `scan-pool-activity.mjs` |
| 5 | Dynamic fees are live: 4 of 1,462 pools charged different fees between swaps (0.000%→0.300%, 0.328%→0.528%). Range 0%–3% | `scan-dynamic-fees.mjs` |
| 6 | 36 corporate actions / 29 tokens / 86 days, accelerating. CRWD 4:1 split. **WEEK: split applied then REVERTED 15 min later** | `scan-corporate-actions.mjs` |
| 7 | Equity feeds update 24/5; all 5 sampled were 36–45h stale on a Sunday vs 24h heartbeat. Crypto feeds fresh | `observe-live-feeds.sh` |
| 8 | **20,925 Stock Token pools, 19,744 (94%) carry a hook, 750 distinct hook contracts.** NVDA alone has 14,436 pools | `census-equity-pool-hooks.mjs` |
| 9 | **Corporate-action mispricing is smaller than daily noise.** SPY: multiplier +0.17%, feed moved −0.17%. NVDA: +0.08% vs −0.50%. MSFT: +0.04% vs +0.57% | `measure-corporate-action-impact.mjs` |

## Ideas killed, and by what

| Idea | Killed by | Time spent |
|---|---|---|
| Dividend stripping ("Pendle for stock tokens") | Fact 6 + yields 0.1–2.5%/yr — too thin to build a market on | ~10 min |
| Portfolio NFT with transferable leaderboard | Adversarial product review: transferability and the leaderboard cancel out (sellable rank = seasoned-account market); optimal play is 100% one memecoin, which routes around the equity half | ~1 h |
| Market-hours dynamic-fee hook | Fact 8 — 94% of equity pools already hooked, 750 implementations | ~30 min |
| Corporate-action arbitrage capture | Fact 9 — the effect is 2–14× smaller than ordinary price noise, and both land in the same feed round | ~20 min |

## Unresolved / not yet measured

- **Holder overlap (the decisive PMF question).** Do real EOAs actually *hold* both a
  Stock Token and a memecoin, or do the mixed pools just reflect router hops?
  Pool activity ≠ portfolio intent. Blocked on public-RPC rate limits; needs an
  Alchemy key or a narrower approach. `scan-holder-overlap.mjs`
- **Is there an NFT marketplace on chainId 4663?** Never checked.
- **Real round-trip cost** of a multi-leg basket against pinned mainnet state.

## What is built and working

`fix/phase0-review-defects` — 42 passing tests, survived an independent adversarial
review, two real defects found and fixed. Execution-safety engine for Stock Token →
USDG swaps: identity mapping, feed validity, issuer pause, ERC-8056 corporate-action
windows (including the reversal case), 18/8/6 decimal normalisation, EIP-712 intents
bound to the policy address and a config epoch, actual-balance-delta accounting,
atomic rollback. Nothing deployed anywhere yet.
