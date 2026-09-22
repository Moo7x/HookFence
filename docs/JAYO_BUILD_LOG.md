# Jayo build log

Running record of what is implemented, what is proposed, and what evidence
supports each differentiation claim. Kept short and updated as work lands.

**Product promise (frozen):**
> Build a funded token basket, own and transfer it as one position, copy its
> allocation using your own funds, and withdraw its underlying assets.

---

## Milestone 1 — one complete journey

| Step | Status |
|---|---|
| 1. Buy-side reference pricing (USDG to Stock Token) | **DONE** |
| 2. `JayoBasket` ERC-721 + per-tokenId isolated holdings | not started |
| 3. Fund a basket: USDG to N assets, multi-leg | not started |
| 4. Preview expected costs/amounts before execution | not started |
| 5. Transfer + revoke prior owner's authority and delegations | not started |
| 6. Copy an allocation into a separately funded position | not started |
| 7. In-kind redemption under a stale feed | not started |
| 8. Minimal interface | not started |
| 9. Pinned-fork check of executable amounts at demo size | not started |

---

## Step 1 — buy-side pricing (implemented)

**The problem.** The Phase 0 engine priced only Stock Token to USDG.
`requiredMinOut` looked up `_stockTokens[tokenIn]` and `_quoteAssets[tokenOut]`,
so a buy reverted `TokenNotSupported(USDG)`. Jayo funds baskets by buying, so
this blocked everything downstream.

**What was already reusable, verified by reading the source rather than assumed:**

- `V4ExactInputAdapter` is fully direction-agnostic. It takes
  `(key, zeroForOne, tokenIn, tokenOut)` and validates they match the reviewed
  route. No change needed.
- `ExecutionGateway`'s accounting, allowance handling and rollback are
  direction-agnostic. One change was needed: `_assertInstrumentUnchanged`
  assumed the Stock Token is `tokenIn`, true only when selling.

So the new work was **pricing**, not execution plumbing.

**Approach chosen.** The policy derives the direction from its own reviewed
configuration rather than taking it as a caller-supplied argument.

- Considered: a separate `requiredMinOutBuy(...)` entry point. Rejected — two
  near-identical functions drift apart, and the instrument checks would be
  duplicated.
- Considered: a `direction` field on the intent. Rejected — a caller could
  declare it wrongly. Deriving it from configuration cannot be spoofed.
- Implemented: `_resolveDirection(tokenIn, tokenOut)` returns
  `(stockToken, isSell)`. Exactly one side must be a configured Stock Token and
  the other a configured quote asset. Stock-for-stock is rejected outright — it
  would need two instrument checks and a cross rate, and is not a reviewed route.
- `instrumentOf(tokenIn, tokenOut)` added to `IExecutionPolicy` so the gateway
  re-checks the right token after execution on either leg.

**Maths.** Both legs are the same two steps — value the input in USD, convert
that USD to the output token — with only the feeds swapping roles:

```
SELL:  usd = amountIn * stockPrice / 10^stockDec
       out = usd * 10^quoteDec * 10^quoteFeedDec / (10^stockFeedDec * quotePrice)

BUY:   usd = amountIn * quotePrice / 10^quoteDec
       out = usd * 10^stockDec * 10^stockFeedDec / (10^quoteFeedDec * stockPrice)
```

Two 512-bit `mulDiv`s per leg; both truncate, so a minimum output is never
overstated on either side. The corporate-action multiplier is absent from both —
the feed already prices one whole token, so applying it on the way in would be
as wrong as on the way out.

**Instrument checks are identical on both legs.** A stale feed, an issuer pause
or a corporate-action window makes a Stock Token untradeable, not merely
un-sellable. A buy path that skipped them would be the obvious way to get this
wrong, so each is asserted separately for the buy direction.

**Tests** — `test/unit/BuySidePolicy.t.sol`, 16 tests including 1 fuzz @ 512 runs.

The anchor test is the round trip: value 10 Stock Tokens into USDG, then value
that USDG back into Stock Tokens. Any direction-confusion bug — swapped feeds,
inverted decimals, a multiplier applied to one leg only — breaks it loudly.

```
10e18 stock -> 2,550.000000 USDG -> 10e18 stock   (exact)
```

A fuzz test asserts across price and size that a round trip can never
*manufacture* value, only lose truncation dust.

**Suite:** 58 passing, up from 42. No existing test changed behaviour.

---

## Differentiation ledger

Maintained per the review instruction: what exists elsewhere, what Jayo improves,
and what evidence supports it. Claims move from *proposed* to *supported* only
when something verifiable backs them.

| Claim | Status | Evidence |
|---|---|---|
| Asset-bearing NFTs are not new | **Acknowledged prior art** | StonkBrokers documents Stock-Token-bearing NFTs with token-bound wallets and an NFT AMM on this chain. We do not claim to invent this. |
| User-configurable allocations | Proposed | Not yet built; StonkBrokers' configurability not yet examined in detail. |
| In-kind redemption independent of live pricing | Proposed | Not yet built. This is the differentiator most likely to be real, because it resolves a contradiction the sell-only design could not: a position whose exit depends on a feed that sleeps 24/5 is not reliably redeemable. |
| Ownership-epoch attribution of performance | Proposed | Not yet built. |
| Execution transparency (pre-trade costs, post-trade actuals) | Partly supported | The gateway already measures real recipient balance deltas rather than trusting adapter return values (Phase 0). Pre-trade preview not yet built. |

---

## Open questions, to research when they block work

- Does an NFT marketplace on chainId 4663 support arbitrary ERC-721s? Affects
  whether transfer has a venue, not whether it works.
- Executable cost of a multi-leg basket buy at demo size on a pinned fork.
- Which assets have routes usable at demo size — earlier sampling was too narrow
  to settle this, and the conclusion drawn from it was overstated.
