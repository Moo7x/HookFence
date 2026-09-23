# Jayo build log

Running record of what is implemented, what is proposed, and what evidence
supports each differentiation claim. Kept short and updated as work lands.

**Product promise (frozen):**
> Build a funded token basket, own and transfer it as one position, copy its
> allocation using your own funds, and withdraw its underlying assets.

---

## RESUME HERE

**Last worked:** 2026-09-22 · **Deadline:** 2026-10-04 15:59 UTC
**Branch:** `fix/phase0-review-defects` @ `f3c3fb4` (pushed to private GitHub)
**Tests:** 93 passing, 0 failing, from a clean build.

**Run the demo:** `./scripts/run-demo.sh` → <http://127.0.0.1:5173>
(starts anvil, deploys everything with mock assets, serves the interface)

**Milestone 1 is COMPLETE.** The whole product promise works end to end and was
driven in a browser against a live chain, not merely unit-tested.

### Next up, in order

1. **Assess product improvements** — compare against competitor workflows
   (StonkBrokers first, see the ledger below), pick the two strongest
   improvements, state user problem / benefit / cost / how to test the benefit.
   This is the current instruction from review and nothing else should start
   before it.
2. **Pinned-fork check** — executable amounts and costs at demo size against
   real Robinhood Chain mainnet state. Mock-only tests cannot establish live
   route viability.
3. **Testnet deployment** — blocked on a human funding a wallet, see
   `MANUAL_ACTIONS.md`.
4. Demo script, README, submission copy.

### Decisions already frozen — do not reopen

- **Product:** Jayo, with HookFence as its execution engine underneath. Settled
  after four abandoned directions; the churn itself became the main risk. See
  `STATUS_FOR_REVIEW.md` §6 for what was killed and whether each kill was sound.
- **Promise:** build a funded basket, own and transfer it as one position, copy
  its allocation with your own funds, withdraw its underlying assets.
- **No rebalancing.** Deliberately cut: fee pump, enables a sale/rebalance race,
  largest source of accounting bugs.
- **No project token.** Circular value, judges mark it down.
- **Solvency invariant is `liabilities <= balance`**, never equality — donations
  break equality.

---

## Milestone 1 — one complete journey

| Step | Status |
|---|---|
| 1. Buy-side reference pricing (USDG to Stock Token) | **DONE** |
| 1a. Independently-derived pricing spec + boundary tests | **DONE** |
| 1b. Executed buy through gateway + v4 adapter | **DONE** |
| 2. `JayoBasket` ERC-721 + per-tokenId isolated holdings | **DONE** |
| 3. Fund a basket: USDG to N assets, multi-leg | **DONE** |
| 4. Preview expected costs/amounts before execution | **DONE** (`previewCreate`) |
| 5. Transfer + revoke prior owner's authority and delegations | **DONE** |
| 6. Copy an allocation into a separately funded position | **DONE** |
| 7. In-kind redemption under a stale feed | **DONE** |
| 8. Minimal interface | **DONE** |
| 9. Pinned-fork check of executable amounts at demo size | **not started** |

### Verified by running it, not by assuming

| Step | Observed |
|---|---|
| Preview | AAPL reference 23.529412, floor 23.411765 |
| Create | actual 23.456072 — between the two (pool fee + impact) |
| Transfer | manager cleared, version 0 → 1 |
| Authority | original owner and delegate both locked out; redeem rejected |
| Copy | new position, same recipe, funded by copier, source untouched |
| Stale | feeds advanced 48.1h past the 24h heartbeat |
| Create again | correctly blocked |
| Redeem | AAPL 23.456072 + NVDA 26.583133 returned in kind anyway |

### Where the code lives

```
contracts/src/basket/JayoBasket.sol        ERC-721 + holdings + create/copy/redeem
contracts/src/core/ExecutionGateway.sol    intent auth, settlement, accounting
contracts/src/policy/StockToken…Policy.sol direction-aware pricing, instrument checks
contracts/src/adapters/V4Exact…Adapter.sol one reviewed v4 route
contracts/script/DeployJayoLocal.s.sol     local deploy, all mocks
app/index.html                             the interface
```

### Known limits, already documented

- Max basket size is bounded by pool depth and the shortfall allowance. Oversized
  creations are rejected with `OutputBelowFloor` naming both numbers.
- Everything is mocked. Real `v4-core` PoolManager, but mock tokens, feeds, hooks.
- No fork test, no deployment, no addresses anywhere.
- No invariant tests; four fuzz tests exist.
- No static analysis — Slither is not installed in this environment.

### Traps that have cost debugging time — read before writing tests

1. **An external call while a Foundry prank is armed consumes the prank.** The
   call under test then runs as the test contract and fails on access control,
   which looks exactly like a contract bug. Cache values in `setUp` or build
   arguments before arming. Cost so far: three cycles.
2. **Under `via_ir`, a local derived from `block.timestamp` is rematerialised
   after `vm.warp`.** So `uint256 at = block.timestamp + 600; vm.warp(at + 1)`
   does not land on `at + 1`. See `test/unit/CompilerProbe.t.sol`.
3. **Large heredocs in bash mangle regexes and long Solidity files.** Use the
   Write tool for anything substantial.

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

## Step 1a — independent verification of the pricing (implemented)

A round-trip test cannot catch a mistake made *symmetrically* in both directions:
a wrong exponent used consistently on both legs cancels out and the round trip
still closes. So `docs/MATHS_SPEC.md` states the formulas, units and rounding,
and derives absolute expected values **from the economics rather than from the
code**. `test/unit/PricingSpec.t.sol` asserts them.

Nine cases, each carrying its economic sanity check alongside the raw number:

| Case | Configuration | Check |
|---|---|---|
| §4.1 | 18/6 dp, feeds 8/8, $255 / $1.00 | $2,550 ÷ $255 = 10 tokens |
| §4.2 buy | **8/18 dp, feeds 18/6**, $50 / $2.00 | 100 × $2 = $200; $200 ÷ $50 = 4 tokens |
| §4.2 sell | same | 4 × $50 = $200; $200 ÷ $2 = 100 tokens |
| third combo | **6/18 dp, feeds 6/18**, $10 / $0.50 | both legs |
| §4.3 | smallest non-zero buy | hand-derived 3921568627, truncated from …627.45 |
| truncation | non-terminating division | doubling input never more than doubles output |
| dust | 2 dp stock at $1,000,000 | floors to zero rather than reverting |
| §4.4 | **non-unit multiplier 1.5e18** | neither leg moves, and the absolute values still hold |
| magnitude | quantifies the double-count bug | +0.057% at the live AAPL multiplier, +300% after a 4:1 split |

Three different decimal combinations prove nothing is hardcoded — the policy
reads `decimals()` from the token and the feed rather than assuming 18/6/8.

## Step 1b — executed buy (implemented)

`test/unit/BuyExecution.t.sol`, 8 tests. This tests what the **pool pays**, as
distinct from what the policy **computes**.

**Mocked vs real, stated plainly.** The Stock Token, USDG, both Chainlink feeds,
both hooks and the pool liquidity are local fixtures. The `v4-core` `PoolManager`
is real — swap accounting, tick maths, hook dispatch and settlement are the
actual Uniswap v4 implementation, deployed fresh in `setUp()`. So "the pool paid
X" is a genuine v4 result against mock assets.

Measured on the honest pool, buying with 2,550.000000 USDG:

| | Value (18 dp) |
|---|---|
| Reference, computed | 10.000000000000000000 |
| **Executed, pool paid** | **9.967515596737513174** |
| Enforced floor | 9.950000000000000000 |

The 0.325% gap is the 0.30% pool fee plus price impact. Reporting the reference
as though it were the fill would be a misrepresentation, so a test pins the
distinction.

Rejection path: on the adversarial pool the fill lands under the floor and the
settlement reverts with `OutputBelowFloor(wouldReceive, floor)`, where
`wouldReceive` is measured by letting an unconstrained settlement run and rolling
it back. Asserted afterwards: no balance moved for trader, gateway or adapter; no
residual allowance; **and the nonce was not burned** — a reverted settlement is
indistinguishable from one that never happened.

Also asserted: policy rejections (stale feed, paused oracle) reach the executed
path and not merely the view; and route directions are independent, so enabling a
sell route does not implicitly enable its inverse.

**Suite: 75 passing.**

---

## Testing note — a trap that has cost three debugging cycles

An external call made while a Foundry prank is armed **consumes the prank**:

```solidity
vm.prank(trader);
gateway.settle(_buildIntent(...), ...);  // _buildIntent reads policy.policyVersion()
                                         // -> prank consumed -> settle runs as the
                                         //    test contract -> UnauthorisedCaller
```

The failure looks like an access-control bug in the contract under test. It is
not. Fix: cache `policyVersion` / `configEpoch` in `setUp`, or build the intent
before arming the prank.

Related and separate: under `via_ir` a local derived from `block.timestamp` is
rematerialised after `vm.warp` changes it. See `test/unit/CompilerProbe.t.sol`.

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
| Execution transparency (pre-trade costs, post-trade actuals) | **Implemented capability — NOT a verified difference** | The gateway measures real recipient balance deltas rather than trusting adapter return values, and `BuyExecution.t.sol` shows reference and executed prices differ by 0.325% on an honest pool. Measuring balance changes is sound engineering, not by itself an advantage — competitors may well do the same. Pre-trade preview not yet built. No competitor comparison performed. |

---

## Implemented capabilities vs verified competitive differences

Kept separate deliberately. Nothing moves to the second list without a checked
source.

**Implemented capabilities** — true of our code; unknown whether others match:

- buy and sell legs priced from the same validated configuration
- instrument checks applied identically on both legs
- real balance-delta accounting rather than trusting adapter return values
- atomic rollback with no nonce burn on failure
- direction-specific route allowlisting
- decimals read from contracts rather than assumed

**Verified competitive differences:** *none established yet.* No competitor code
or documentation has been examined in enough detail to claim one.

---

## Open questions, to research when they block work

- Does an NFT marketplace on chainId 4663 support arbitrary ERC-721s? Affects
  whether transfer has a venue, not whether it works.
- Executable cost of a multi-leg basket buy at demo size on a pinned fork.
- Which assets have routes usable at demo size — earlier sampling was too narrow
  to settle this, and the conclusion drawn from it was overstated.
