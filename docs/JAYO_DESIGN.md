# Jayo — concrete designs

**Date:** 2026-09-20 · **Deadline:** 2026-10-04 15:59 UTC (~13 days)
**Status:** design proposals. Nothing built. Pick one.

---

## The problem nobody on this chain has solved

Verified on mainnet (`scripts/observe-live-feeds.sh`, Sunday 2026-09-20 09:09 UTC):

| Feed | Class | Last update | Age |
|---|---|---|---|
| AAPL/USD | equity | Fri 15:11 | **42.0 h** |
| SPY/USD | equity | Fri 12:22 | **44.8 h** |
| NVDA/USD | equity | Fri 19:55 | 37.2 h |
| ETH/USD | crypto | Sun 05:24 | 3.8 h |

**Robinhood's equity oracles update 24/5. The AMM trades 24/7.**

So for roughly 65% of every week, an equity pool is quoting a price that nothing is
standing behind, while remaining fully open for business. Whoever knows something
the pool doesn't — a weekend news event, a Monday gap — takes the LP's money at
Friday's price. Liquidity providers in Stock Token pools are writing a free
option every weekend and being paid the same 0.3% they get at noon on Tuesday.

**No other chain has this problem, because no other chain has assets whose oracle
goes to sleep.**

---

## Design A — Portfolio NFT + Market-Hours Hook  ★ recommended

Two components. The product is the portfolio; the technical depth is the hook.

### A1. The Portfolio NFT

- Deposit USDG → choose an allocation → contract buys the real basket on Uniswap v4
- An **ERC-721 holds the basket** (per-tokenId isolated accounting in one vault)
- Transfer the NFT → the whole portfolio transfers
- Leaderboard ranks live portfolios by real P&L in USDG

**Verified launch assets** (pools traded in ≥5 of 6 windows over 28 h — continuous,
not launch pumps):

| Asset | Pair | Swaps | Windows |
|---|---|---|---|
| ETH | ETH/USDG | 189 | 6/6 |
| GOOGL | GOOGL/USDG | 34 | 5/6 |
| NVDA | USDG/NVDA | 28 | 5/6 |
| ROBIN | ROBIN/USDG | 75 | 6/6 |
| CASHCAT | CASHCAT/USDG | 55 | 5/6 |
| AI | AI/USDG | 80 | 6/6 |

SPY, AAPL and MSTR are **excluded** — no sustained USDG liquidity. An earlier draft
of the plan listed them; that was based on a 5-minute sample and was wrong.

### A2. The Market-Hours Hook

A Uniswap v4 hook for Stock Token pools. Pool created with
`DYNAMIC_FEE_FLAG (0x800000)`. In `beforeSwap`:

```
1. FAIL CLOSED — revert the swap entirely if:
     - token.oraclePaused()                      (issuer paused for a corporate action)
     - within corporateActionBuffer of effectiveAt (ERC-8056 transition window)
   → reuses StockTokenReferencePolicy, already written and tested

2. PRICE THE RISK — otherwise return a dynamic LP fee that scales with feed age:
     age <  1h   ->   5 bps    market open, oracle fresh, cheapest
     age <  6h   ->  30 bps    normal
     age < 24h   -> 100 bps    overnight
     age >= 24h  -> 250 bps    market closed — LPs are writing a weekend option

3. DEVIATION SURCHARGE — if |pool price - oracle price| > threshold, widen further.
   Someone is arbitraging a stale pool; the LPs should be paid for it.
```

**Why this must be a hook and cannot be a router:** a router protects *its own*
callers. A hook protects *the pool* — every LP and every trader, including people
who have never heard of Jayo. That is a different beneficiary, and it is the honest
reason the hook earns its place rather than being decorative.

### A3. How the two connect

Jayo portfolios are the first users of Jayo pools. The portfolio needs to buy
equities; it buys them where the LPs are not being quietly robbed. The safety
engine already in this repo becomes the hook's brain.

### The 30-second demo

> "It's Sunday. NVDA's oracle has been asleep for 37 hours — here it is on mainnet.
> In an ordinary pool I can trade against Friday's dead price for 30 bps.
> In Jayo's pool the fee is 250 bps, because the LP is taking real risk.
> And if I try this during a corporate action, the pool refuses outright."

Every number is live mainnet data, not a fixture.

### Honest constraints

| Constraint | Reality |
|---|---|
| **Cold start** | The hook is in `PoolKey`, so it only works on pools we create. Ours start empty. For the hackathon we seed our own pool; real adoption needs LPs. **Must be stated plainly in the README.** |
| **Portfolio routing** | Buys route to *existing* pools (real liquidity) and to *our* pool where it exists. Not one unified venue. |
| **Prior art** | Oracle-linked dynamic fees are a known idea in Uniswap research. The *market-hours* application to assets with sleeping oracles is what is new. We do not claim to have invented dynamic fees. |
| **Fee curve is a judgement call** | The bps numbers above are a starting point, not a derived optimum. Say so. |

### Build cost

Hook ≈ 2 days (≈150 lines + tests; the policy it calls already exists and is tested).

---

## Design B — Portfolio NFT only

Design A without A2. Safest to finish; lowest innovation score.

Keeps: real custody, verified assets, leaderboard, transferability, the existing
safety engine protecting Jayo's own trades.

Loses: the hook, the market-hours insight, and the only part of this that is
genuinely impossible elsewhere. Asset-holding NFTs already exist
(Charged Particles), so B's mechanism is not new — only its market is.

---

## Recommendation

**Design A.** The hook is ~2 days against a 13-day budget, it is the one component
no other gallery project has, it turns a verified mainnet observation into working
code, and it is exactly what the teammate's original instinct pointed at.

If we fall behind, **A2 is droppable without breaking A1** — the portfolio still
works, we just lose the differentiator. That is the right thing to have as the
cut line, rather than discovering late that the core does not work.

---

## What I am not claiming

- Not the inventor of asset-holding NFTs (Charged Particles).
- Not the inventor of oracle-linked dynamic fees (Uniswap research).
- Not that Jayo pools will attract liquidity — cold start is unsolved.
- Not that mixed equity/meme portfolios are proven in demand. The *behaviour* is
  verified (NVDA/SI at 849 swaps, SCHIFFY/GLD, musebook/META); the demand is not.
