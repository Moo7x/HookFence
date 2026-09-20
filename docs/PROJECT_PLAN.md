# Project plan — Portfolio NFTs on Robinhood Chain

**Working name:** SLATE (alternatives in §11 — naming is the team's call)
**Date:** 2026-09-20
**Deadline:** 2026-10-04 15:59 UTC (~13.5 days)
**Status:** proposed, awaiting sign-off. Nothing built yet for this.

---

## 1. The idea

**Your investment portfolio becomes a single NFT that holds real assets, and that
you can sell as one object.**

- Deposit USDG, choose an allocation across tokenized equities (NVDA, SPY, AAPL…),
  ETH, and memecoins.
- The contract executes the real buys through Uniswap v4. The NFT **holds** the
  resulting basket — not a receipt, not paper trading.
- Transfer the NFT and the entire portfolio transfers with it. One transaction
  sells a whole strategy.
- A leaderboard ranks live portfolios by real P&L, which makes it a game rather
  than a spreadsheet.
- Equity legs execute through the safety engine already built in this repo
  (oracle validity, corporate-action windows, settlement accounting).

The one-line pitch:

> **The only chain where you can hold tokenized NVDA and a dog coin in the same
> basket — so we made the basket ownable, tradeable and competitive.**

---

## 2. Where this came from — full provenance

Asked for explicitly, because this project has already burned time on ideas that
sounded good and weren't. Here is the actual chain of reasoning.

**Origin: your teammate.** The NFT-as-portfolio + leaderboard + competition
concept is his, from his message. I did not generate it. My contributions are
(a) the change from paper trading to real custody, (b) removing the token,
(c) verifying it against the live chain, and (d) the execution-safety layer.

**What I actually did before proposing it:**

1. Read Robinhood Chain docs end to end and verified every claim against live
   mainnet (chainId 4663) with `cast` — ERC-8056 multiplier, `oraclePaused`,
   6-decimal USDG, 8-decimal feeds. Recorded in `docs/PHASE0_EVIDENCE.md` §2.
2. Pulled the **complete corporate-action history** of the chain: 36
   `UIMultiplierUpdated` events, 29 tokens, 86 days. Found CRWD's 4:1 split and
   a split on WEEK that was **applied then reverted 15 minutes later**.
3. Killed my own best idea with that data. Dividend-stripping ("Pendle for
   stock tokens") looked strong until the numbers came back: yields are
   0.02–0.45% per payment, ~0.1–2.5%/yr. Too thin. Dropped in 10 minutes
   rather than 3 days.
4. Surveyed live Uniswap v4 activity: ~1,000 swaps/minute, 837k pools created.
5. **Corrected a false negative of my own.** My first pool query reported "0
   swaps ever" because I was swallowing RPC errors. Re-ran with error surfacing;
   the chain is extremely active. Also fixed two `topics[0]` vs `topics[1]`
   indexing bugs. Every number in §3 is from the corrected queries.
6. Sampled 4 separate time windows across ~11 hours to check volume is
   **sustained**, not a one-off burst.
7. Decoded the actual fee charged on 10,946 live swaps.

**The insight that made it click:** step 6 showed people are already trading
`ELIZA/NVDA`, `NVDA/SI`, `musebook/META`, `CHONK/LLY` — tokenized equities paired
directly against memecoins, with sustained volume. **Users are already building
mixed equity/meme portfolios by hand.** Your teammate's instinct pointed at a
behaviour that is measurably happening.

**What this is not:** not a copy of a known protocol. §7 states the prior art
plainly, including the parts of the mechanism that are not novel.

---

## 3. Verified facts this plan depends on

Every one reproducible. Scripts in `scripts/`, raw output in `contracts/reports/`.

| # | Fact | Evidence |
|---|---|---|
| 1 | Uniswap v4 is live and very active on Robinhood Chain | ~1,000 swaps/min; 8,121 swaps sampled across 4 windows / 11h; 837k pools created |
| 2 | **Tokenized equities really trade on-chain** | `ELIZA/NVDA` 88 swaps, `NVDA/SI` 84 (4/4 windows), `musebook/META` 70 (4/4), `CHONK/LLY` 60, `SPY/USDG` 58 |
| 3 | Equities are already being paired **against memecoins** | see #2 — this is the behaviour the product formalises |
| 4 | USDG is a real quote asset | `ETH/USDG` in 4/4 windows, `ROBIN/USDG` 4/4, `CASHCAT/USDG`, `UIU/USDG` |
| 5 | **Hooks are widely deployed** | 19 of top 28 pools carry a hook |
| 6 | **Dynamic fees are live, and fees really do change between swaps** | 4 of 1,462 pools charged different fees in one window: 0.000%→0.300%, 0.328%→0.528%. Fees range 0%–3% |
| 7 | Corporate actions are frequent and can be **reversed** | 36 events/86 days, accelerating; WEEK: `1e18→2e18` then `2e18→1e18` 15 min later; CRWD 4:1 split |
| 8 | Stock feeds go stale outside market hours | All 5 equity feeds 36–45h old on a Sunday vs 24h heartbeat; both crypto feeds fresh |

Fact 6 is worth pausing on: your teammate's original intuition — *"it shows 1%
and then the hook makes it 5%"* — is **not hypothetical on this chain.** It is
rare (~0.3% of pools) but real and measured. That makes the safety layer we
already built genuinely relevant rather than theoretical.

---

## 4. Why this can place well

Mapped to the four published criteria.

**Innovation and Creativity.** The product is new even though the parts are not:
a per-user, individually-tradeable portfolio NFT mixing tokenized equities with
memecoins, on the only chain where both exist in one AMM. The gallery has index
funds, risk scanners and AI agents — nothing that makes a portfolio itself an
ownable, transferable object with a competitive layer.

**Real Problem Solving.** Fact #2/#3: people are manually assembling mixed
baskets right now, one swap at a time, with no way to exit as a unit, no way to
copy someone else's allocation, and no shared record of who is any good at it.

**Product-Market Fit.** There is a real loop: mint → compete → climb → sell your
NFT for more than you put in because your track record is attached to it.
Speculation and status are the two things this chain demonstrably already has.

**Smart contract quality.** The strongest card, and it is already half-played:
42 passing tests, an independent review survived, two real defects found and
fixed, and an execution-safety engine grounded in verified mainnet behaviour.
Very few hackathon submissions will have a documented adversarial review.

**USDG.** Structural, not cosmetic — it is the denomination unit for deposits,
NAV, P&L and the leaderboard.

**Robinhood Chain.** Structural. The product is impossible elsewhere: no other
chain has tokenized equities and memecoins in the same AMM.

---

## 5. Honest weaknesses, and what we do about them

Stated up front so they get challenged now rather than in judging.

| # | Problem | Severity | Mitigation |
|---|---|---|---|
| 1 | **Memecoin valuation.** No Chainlink feed. Spot price from a thin pool is manipulable, so the leaderboard could be gamed by moving an illiquid pool before a snapshot. | **HIGH** | Score the leaderboard from a **TWAP over the scoring window**, not spot. Require a minimum pool liquidity for an asset to be selectable. Cap any single non-feed asset's weight (e.g. 30%). Curated asset list at launch. |
| 2 | **Custody risk.** The vault holds real user funds. Biggest change from the current design, which custodies nothing. | **HIGH** | Per-NFT isolated accounting, no pooled balances. Withdraw/burn path that cannot be blocked by the owner. Invariant tests: sum of per-NFT holdings == vault balance, always. No admin withdrawal function at all. |
| 3 | **Thin memecoin liquidity** → huge slippage or failed mints. | MEDIUM | Per-leg slippage bounds; partial-fill rejection; the mint reverts atomically if any leg fails. Liquidity floor in curation. |
| 4 | **Prior art exists** for NFTs that hold assets (§7). | MEDIUM | Do not claim primitive novelty. Claim the product and the market. State prior art in the README ourselves. |
| 5 | **Scope is large** for 13 days. | MEDIUM | Phased (§9) with a working deployable product at the end of Phase 2. Everything after is upside. |
| 6 | Equity feeds stale nights/weekends (fact #8) | MEDIUM | NAV uses last-good feed with explicit staleness labelling in UI. **Rebalances involving equities are blocked while stale** — the existing policy already does this. Judging demo can use either state. |
| 7 | Corporate actions can be **reversed** (fact #7) | LOW-MED | Already handled by the corporate-action window in `StockTokenReferencePolicy`, and we have the only test suite that covers a reversal. |
| 8 | Leaderboard could be gamed by minting many NFTs | LOW | Mint fee; minimum deposit; rank by % return with a minimum capital floor. |
| 9 | "Is this gambling?" | LOW | No prize pool, no house take on P&L, no wagering. It is a portfolio tracker with a public ranking. Avoid prize language in copy. |

---

## 6. Architecture

```
                        ┌──────────────────────────┐
   USDG deposit  ──────▶│      PortfolioNFT        │ ERC-721
                        │  tokenId ↔ allocation    │
                        └────────────┬─────────────┘
                                     │
                        ┌────────────▼─────────────┐
                        │     PortfolioVault       │  per-tokenId isolated
                        │  holdings[id][asset]     │  accounting, no pooling
                        └────────────┬─────────────┘
                                     │
                        ┌────────────▼─────────────┐
                        │   AllocationExecutor     │  target weights → legs
                        └──────┬────────────┬──────┘
                               │            │
              equity legs ─────┘            └───── crypto / meme legs
                     │                                    │
        ┌────────────▼─────────────┐          ┌───────────▼──────────┐
        │  ExecutionGateway   ★    │          │  V4ExactInputAdapter │ ★
        │  StockTokenRefPolicy ★   │          └───────────┬──────────┘
        └────────────┬─────────────┘                      │
                     └──────────────┬───────────────────────┘
                                    ▼
                          Uniswap v4 PoolManager
                       0x8366a39cc670b4001a1121b8f6a443a643e40951

        ┌──────────────────────────┐   ┌──────────────────────────┐
        │   PortfolioValuation     │   │      Leaderboard         │
        │  Chainlink + TWAP        │──▶│  ranks by % return       │
        └──────────────────────────┘   └──────────────────────────┘

        ★ = already built and tested in this repo
```

**Why equity legs route through the gateway and meme legs don't:** equities have
oracle/corporate-action semantics that need enforcing; memecoins have no feed and
no issuer, so there is nothing to enforce beyond slippage. Forcing both down the
same path would be dishonest engineering.

---

## 7. Prior art — stated plainly

We will put this in the README ourselves rather than let a judge find it.

| Prior work | Relationship |
|---|---|
| Set Protocol / TokenSets, Index Coop | ERC-20 baskets. Fungible, shared, not per-user, not transferable as a unique object. |
| Enzyme Finance | On-chain funds with managers. Vault shares, not NFTs. |
| **Charged Particles** | **NFTs that hold assets. Closest mechanism.** We are not claiming to invent NFT-held value. |
| Uniswap v3/v4 LP positions | NFTs representing value. Same lineage. |
| RWA.Index (this hackathon) | ERC-4626 AI-managed index of tokenized stocks. Closest competitor — but a single shared fund with an AI manager, not per-user competing portfolios. |

**Our claim is product-level, not primitive-level:** the combination of per-user
portfolio NFTs, equities + memecoins in one basket, a competitive leaderboard,
and equity-aware execution safety, on the one chain where that mix exists. We do
not claim to have invented asset-bearing NFTs.

---

## 8. What happens to the existing code

| Component | Fate |
|---|---|
| `StockTokenReferencePolicy.sol` | **KEEP** — becomes the equity-leg safety layer |
| `ExecutionGateway.sol` | **KEEP, modify** — add multi-leg batch settlement |
| `V4ExactInputAdapter.sol` | **KEEP, extend** — needs a generic (non-equity) path |
| `IExecutionPolicy` / `IStockToken` / `IAggregatorV3` | **KEEP** |
| All mocks + `HookFenceFixture` | **KEEP** — the harness is reusable as-is |
| 42 existing tests | **KEEP** — they still test the execution layer |
| `ReferenceVault.sol` | **DELETE** — superseded by `PortfolioVault` |
| `BaselineOracleRouter`, `ContextSensitiveHook`, spike tests | **KEEP but demote** to `test/spike/` — they become supporting evidence for the safety layer, not the headline |
| Phase 0 docs | **KEEP** — evidence of rigour, referenced from the README |

Nothing is thrown away. The old project becomes one subsystem of the new one.

---

## 9. Build plan

Full scope. Narrowing points marked, to be used **only if** we hit the dates.

### Phase 1 — Core custody and minting (days 1–3)
- `PortfolioNFT` (ERC-721) + `PortfolioVault` with per-tokenId isolated accounting
- Mint with USDG → execute allocation → NFT holds the basket
- Burn/redeem → sell everything → return USDG
- Transfer moves the whole portfolio
- **Invariant tests**: sum of holdings == vault balance; no path where an NFT owner cannot redeem
- **Gate:** mint + redeem + transfer work on local fork with real v4

### Phase 2 — Execution and valuation (days 4–6)
- `AllocationExecutor`: target weights → ordered swap legs, atomic
- Equity legs through `ExecutionGateway`; crypto/meme legs direct
- `PortfolioValuation`: Chainlink for equities/ETH/USDG, TWAP for memes
- Slippage bounds per leg; atomic revert on any failure
- **Gate:** a real mixed basket (SPY + ETH + a memecoin) mints on a mainnet fork

### Phase 3 — Competition layer (days 7–8)
- `Leaderboard`: % return since mint, minimum capital floor, TWAP-based
- Rebalance path (change allocation on an existing NFT)
- Copy-mint: mint a new NFT with the same allocation as an existing one
- **Gate:** leaderboard ranks correctly and resists a spot-price manipulation test

### Phase 4 — Deployment (days 9–10)
- Testnet deployment (46630) with labelled mocks where mainnet contracts are absent
- **Mainnet-fork integration tests at pinned blocks** — real USDG, real SPY, real v4
- Verified contracts, `docs/DEPLOYMENTS.md`
- **Gate:** addresses recorded, transactions verifiable

### Phase 5 — Interface (days 10–12)
- Mint flow with allocation picker
- Portfolio card: holdings, NAV in USDG, P&L, rank
- Leaderboard view
- Explicit labelling of mock vs fork vs live data
- **Narrowing point:** if behind, ship mint + portfolio card + leaderboard only

### Phase 6 — Submission (days 12–13.5)
- README, architecture, threat model, demo script
- 2-minute recording
- HackQuest form (300-char fields, pre-written)
- **Narrowing point:** docs are non-negotiable; polish is negotiable

### Reserve
Day 13.5 → deadline: buffer. Not scheduled.

---

## 10. Kill conditions

Stop and reassess if:

1. A mixed-asset mint cannot execute atomically on a mainnet fork by end of Phase 2.
   *(Tests the core assumption: that a contract can actually buy this basket.)*
2. Memecoin TWAP valuation cannot be made manipulation-resistant at acceptable
   gas by end of Phase 3. → fall back to **feed-priced assets only**, drop
   memecoins from scoring but keep them holdable.
3. Custody invariants cannot be proven by end of Phase 1. → do not ship a vault
   holding user funds.

---

## 11. Open questions for the team

1. **Name.** SLATE / BASKET / MOSAIC / PORTFOLIO WARS / something of yours.
   Constraint: must not imitate Robinhood branding.
2. **Asset list at launch.** Proposal: 4 equities (SPY, NVDA, AAPL, MSTR),
   ETH, USDG, and 2–3 memecoins with verified sustained liquidity.
3. **Token: confirmed dropped?** My recommendation is yes — burn-to-rebalance and
   buyback-and-burn are circular value with no external revenue, and judges
   consistently mark that down. The NFT alone is the stronger product.
4. **AI avatars** — keep (your teammate's idea, cheap, good for the demo) or cut?
   Recommend keep, generated off-chain at mint, stored as metadata.
5. **Leaderboard cadence.** Weekly as proposed, or continuous?

---

## 12. What I will not claim

- Not a new primitive. Asset-bearing NFTs exist (§7).
- Not the only on-chain enforcement project (ArbiGuard, RWA.Index, Mandate).
- Not proof that mixed portfolios are in demand — fact #3 shows the behaviour
  exists, not that it scales.
- No guaranteed placement.
