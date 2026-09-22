# Status report — for the independent reviewer

**Date:** 2026-09-22 · **Deadline:** 2026-10-04 15:59 UTC (~12 days)
**Repo:** `C:\Users\Mega-PC\Desktop\singapore_hack` · remote `github.com/Moo7x/HookFence.git`
**Commits are local, not pushed.**

Your review of `976ec9a` was actioned in full. Since then the project also did
substantial chain research which changes the product picture materially. Both
parts are below, kept separate as you asked.

---

## 1. Branch state

```
master                      976ec9a   (preserved exactly as you left it)
fix/phase0-review-defects   79fbfbe   (current)
  79fbfbe  Add idea slate: six researched, scored, buildable directions
  5851f0d  Add chain measurement scripts and findings log
  e855682  Add chain-research scripts and the Portfolio NFT project plan
  ce2a21f  Fix two defects from independent review; correct evidence claims
```

`ce2a21f` is the repair commit and contains **only** correctness work, per your
instruction to keep the product-expansion decision separate. Everything after it
is research and documentation; no product code was written.

**Clean-state verification:** `forge clean && forge test` → **42 passed, 0 failed,
0 skipped**, 7 suites. Was 18.

---

## 2. Your two defects — both fixed

### Defect 1 — replacement policy inherits old signatures

**Fixed.** Root cause restated precisely: `policyId` and `policyVersion` are both
values the policy contract reports *about itself*, so binding them binds a claim,
not an identity.

`ExecutionIntent` now carries `address policy` and `uint64 configEpoch`.
`configEpoch` is a gateway-owned monotonic counter incremented by **both**
`setPolicy` and `setAdapter`. `_validate` reverts `PolicyContractMismatch` /
`ConfigEpochMismatch`. Typehash updated; both events carry the epoch.

Tests in `test/unit/ReviewRegressions.t.sol`:

| Test | Asserts |
|---|---|
| `test_Regression_ReplacementPolicyCannotReuseOldSignature` | reverts `PolicyContractMismatch`; first asserts the impersonation is genuine (same id, same version, different address) |
| `test_Regression_AdapterConfigChangeBumpsEpoch` | reverts `ConfigEpochMismatch` |
| `test_Regression_SignatureStillWorksWhenConfigUnchanged` | control — same signature settles when config is untouched |

The control exists because without it the first two would also pass if signing
were simply broken.

### Defect 2 — post-effective corporate-action buffer bypassed

**Fixed.** The `newUIMultiplier() == uiMultiplier()` early return is gone; the
window is keyed on `effectiveAt` alone, regardless of whether the change has
already applied. A scheduled multiplier with no effective timestamp fails closed.
A comment blocks reintroduction.

**The more important half was the fixture, and you identified this correctly.**
`MockStockToken.uiMultiplier()` now advances at `effectiveAt`, matching the
ERC-8056 reference. The old mock only changed on a setter call, so it could not
*reach* the state that exposed the bug. Your `TimedMultiplierToken` is carried
into the repo verbatim, labelled as a model of the reference implementation and
not of any verified deployed Robinhood contract.

| Test | Asserts |
|---|---|
| `test_Regression_CorporateActionBufferHoldsAcrossTheTransition` | rejects at `at−`, `at`, `at+1`, `at+59min`, each with the exact `CorporateActionPending` payload |
| `test_Regression_TradingResumesAfterTheBufferElapses` | the instrument is not permanently bricked |
| `test_Regression_MockAdvancesMultiplierAtEffectiveAt` | the fixture really does model ERC-8056 |

---

## 3. A third defect, found while fixing the second

Not in your review. It silently invalidated our own test and is worth knowing
about for any Foundry codebase using `via_ir`.

**A local derived from `block.timestamp` is unsafe to reuse across `vm.warp`.**

```solidity
vm.warp(1_000_000);
uint256 at = block.timestamp + 600;   // reads 1_000_600 correctly
vm.warp(at);                          // -> 1_000_600   fine
vm.warp(at + 1);                      // -> 1_001_201   NOT 1_000_601
```

Not a compiler bug: `TIMESTAMP` is genuinely constant within a transaction, so the
Yul optimiser may rematerialise `block.timestamp + 600` at each use. `vm.warp`
breaks that invariant from outside the EVM. The stack slot is fine —
`console2.log(at)` still prints `1_000_600`; the re-derived use in argument
position drifts.

This made the corporate-action test warp *past* the buffer it was probing, which
briefly looked like a policy defect and was not. Pinned as a characterisation test
in `test/unit/CompilerProbe.t.sol`, which asserts the observed behaviour so a
toolchain change makes it fail loudly. Repository rule: read the value back from
an immutable or storage, or warp to absolute literals.

---

## 4. Your eight evidence corrections — all accepted

| # | Issue | Resolution |
|---|---|---|
| 1 | "Weekend rejection is a defect" overstated | Accepted. Rejecting stale prices is correct behaviour; it is an availability constraint. `PHASE0_EVIDENCE.md` §9.1 rewritten. |
| 2 | 2.5-days / 35% unsupported | Accepted, withdrawn. Feed *age at observation* is not *duration above threshold*. Now stated as one timestamped observation. |
| 3 | No week-long wait needed | Accepted. `EXTENSION_ASSESSMENT.md` no longer gates on seven days. |
| 4 | Misreporting-adapter test logged `B=SETTLED` as a literal | Fixed. Now `B=N/A` via a separate `_recordCOnly` helper, as are the four intent scenarios with no baseline-B analogue. |
| 5 | Quote context read after rollback | Fixed. Context captured *before* `vm.revertToState`. |
| 6 | Scenarios caught any revert | Fixed. `_runHookFenceDetailed` returns the selector; five scenarios assert the exact error. Empty revert now fails explicitly. |
| 7 | Dangling test references, no fuzz, no signature path | Fixed. Every `*.t.sol` reference in `src/` resolves. Added `MultiplierAndUnits.t.sol` (8 tests, 2 fuzz @ 512 runs) and `ReferenceVaultIntegration.t.sol` (8 tests). Signature path covered by §2's three tests. |
| 8 | "Testnet has none" overstated | Accepted. Reworded to exactly what was proven: those specific addresses are empty on testnet. |

**Gas benchmark** now carries your caveat in-code: B executes first and warms
state C reuses; policy reads happen before timing. It shows the overhead is
material and positive, not a controlled benchmark. The number moved because the
new checks are not free:

| | Before | After |
|---|---|---|
| Baseline B | 237,333 | 237,333 |
| HookFence C | 341,710 | 348,860 |
| Overhead | +104,377 | **+111,527** |

---

## 5. Unchanged

A/B/C/D is byte-identical after all repairs:

```
A  quote-derived min (2%)    SETTLED  2511215880
B  ordinary router + floor   REVERTED (floor 2537250000)
C  HookFence full policy     REVERTED (floor 2537250000)
D  honest-hook control       SETTLED  2541716477
```

`assertEq(b.enforcedMin, c.enforcedMin)` still holds. HookFence still has no
advantage over baseline B on output enforcement.

---

## 6. New chain research — this is the part you have not seen

All reproducible from `scripts/` against the public RPC, no API key. Full record
in `docs/FINDINGS_LOG.md`.

| # | Measurement | Script |
|---|---|---|
| M1 | Uniswap v4 on 4663 is very active: ~1,000 swaps/min, **837,000 pools created**, block time ~0.1s | `scan-pool-activity.mjs` |
| M2 | The chain is dominated by **memecoins** — top pools are ROBOCLAW, GARDEN, MERIDIAN, CASHCAT, HOODCATS | `scan-pool-activity.mjs` |
| M3 | Tokenized equities trade **against memecoins** with volume sustained across 5–6 of 6 windows over 28h: NVDA/SI 849 swaps, musebook/META, CHONK/LLY, SCHIFFY/GLD, SPCX/URANUS | `scan-pool-activity.mjs` |
| M4 | Verified sustained USDG liquidity: ETH, GOOGL, NVDA + ROBIN, CASHCAT, AI. **SPY, AAPL, MSTR have none** | `scan-pool-activity.mjs` |
| M5 | Dynamic fees are live: 4 of 1,462 pools charged **different fees between swaps** (0.000%→0.300%, 0.328%→0.528%); observed range 0%–3% | `scan-dynamic-fees.mjs` |
| M6 | **20,925 tokenized-equity pools exist; 19,744 (94%) already carry a v4 hook, across 750 distinct hook contracts.** NVDA alone has 14,436 pools | `census-equity-pool-hooks.mjs` |
| M7 | **Corporate-action mispricing is smaller than daily price noise.** Measured via Chainlink historical rounds: SPY multiplier +0.17% vs feed −0.17%; NVDA +0.08% vs −0.50%; MSFT +0.04% vs +0.57%. Equity feeds publish ~daily, so the multiplier step and the price move land in the **same round** — no pool ever observes a clean multiplier jump | `measure-corporate-action-impact.mjs` |
| M8 | Full corporate-action history: 36 events / 29 tokens / 86 days, accelerating. CRWD 4:1 split. **WEEK: 2:1 split applied then reverted 15 minutes later** | `scan-corporate-actions.mjs` |

### 6.1 What happened to the product direction — the part most worth reviewing

Between your review and now, the project started four different directions and
abandoned all four. Two had written design documents before being dropped. This
is the churn that cost roughly a day and a half, and I want it reviewed rather
than summarised away, because **some of these kills may have been wrong.**

Chronology, with the kill reason and my honest assessment of whether the kill
was justified:

| # | Direction | Killed by | Was the kill justified? |
|---|---|---|---|
| 1 | **Dividend stripping** — separate a Stock Token into price exposure + a tradeable dividend stream, using ERC-8056 multiplier growth as the yield | Measured yields: 0.02–0.45% per payment, ~0.1–2.5%/yr | **Yes.** ~10 minutes to check, numbers are unambiguous, no market at that size. Clean kill. |
| 2 | **Jayo — portfolio NFT** (the teammate's idea, reshaped from paper trading to real custody): deposit USDG, contract buys a real basket of equities + memecoins on v4, an ERC-721 holds it, transferable, competitive leaderboard. `docs/PROJECT_PLAN.md` and `docs/JAYO_DESIGN.md` were both written | An adversarial product critique, not a measurement | **Uncertain — please review this one.** See below. |
| 3 | **Market-hours dynamic-fee hook** — a v4 hook refusing to quote while the equity oracle is asleep or mid-corporate-action, with fee scaled to feed age | M6: 94% of equity pools already hooked, 750 distinct implementations, several with the exact permission set for a custom-curve no-LP venue | **Yes.** Measured, not argued. I proposed it as "the one thing no gallery project has" without first checking what was already deployed on the chain — the wrong question. |
| 4 | **Corporate-action arbitrage** — capture mispricing when a multiplier changes | M7: effect is 2–14× smaller than ordinary daily noise, and both land in the same feed round | **Yes.** ~20 minutes to measure. Would have been a week wasted otherwise. |

**Kills 1, 3 and 4 were made by measurement and I stand behind them.**

**Kill 2 is the one I want challenged.** Jayo was killed by an adversarial agent
I prompted to attack it, not by data. Its strongest arguments were:

- Transferability and the leaderboard cancel out: a buyer can replicate any
  basket with N swaps, so the only non-replicable thing is the rank — and a
  *sellable* rank is a seasoned-account market (mint 20, let variance run, sell
  the winner, burn 19).
- Adverse selection: you only sell a portfolio you think has topped, so listed
  NFTs are systematically the ones about to underperform.
- Ranking by weekly % return on a memechain is a memecoin-beta contest; the
  optimal play is 100% one high-beta memecoin, which routes around the entire
  equity/safety half of the product.
- The demand evidence (M3) is a misread: swap counts show a pool was *routed
  through*, not that any address *holds* both assets — and that gap is still
  unmeasured (§6.3).

Those are real objections. But they are objections of the kind every shipped
product has, and the proposed fixes (soulbind the score, copy-mint instead of
sell, risk-adjusted scoring, in-kind redemption) were never evaluated on their
merits before the direction was dropped. **If you think Jayo was killed
prematurely, say so — the design doc is intact at `docs/JAYO_DESIGN.md` and
`docs/PROJECT_PLAN.md`.**

### 6.2 The methodological failure behind the churn

Stated plainly because it is the actual finding of the last two days, and because
it is a repeat of the error you yourself flagged and corrected in your review:

**I was applying a standard of "must survive adversarial review." Nothing
survives that.** Not RWA.Index, not Mandate, not ArbiGuard — nor, by your own
account, the NYC winners. I collapsed "this idea is fatally broken" into "this
idea has weaknesses," and used the second to kill four consecutive directions.
The user correctly identified this before I did.

You wrote: *"My earlier response went too far in treating the conversation's weak
pitch as sufficient reason to stop the whole project before reviewing its code."*
I then repeated that failure mode four more times at the idea level.

The correction: ideas are now scored on buildability, excitement, sponsor fit and
memorability, with prior art named honestly rather than treated as
disqualifying. That produced `docs/IDEA_SLATE.md`.

### 6.3 Measurement errors of my own, self-corrected

- A first pool query reported "0 swaps ever" because RPC errors were being
  swallowed. Re-run with error surfacing: the chain is extremely active.
- Two `topics[0]` vs `topics[1]` indexing bugs conflated the event signature with
  the pool id.
- A proposed launch asset list (SPY, AAPL, MSTR) was drawn from a 5-minute
  sample; measuring sustained volume across 28h showed none of the three has
  usable USDG liquidity. Corrected to ETH, GOOGL, NVDA.

All figures in §6 come from the corrected queries. Every script is committed so
the numbers can be re-derived rather than trusted.

### 6.3 Still unmeasured

- **Holder overlap.** Whether real EOAs actually *hold* both a tokenized equity
  and a memecoin, or whether the mixed pools in M3 are router hops. Pool activity
  is not portfolio intent. Blocked on public-RPC rate limits; needs an Alchemy
  key. `scan-holder-overlap.mjs` exists but does not complete.
- Whether an NFT marketplace exists on 4663.
- Real round-trip cost of a multi-leg basket against pinned mainnet state.

---

## 7. Open product decision

Your product conclusion still stands: the engineering is sound, the user-facing
advantage is unproven. With ~12 days left the team is choosing between finishing
the execution engine (deploy, fork-test, demo, submit — certain to finish) and
pivoting to one of six researched alternatives in `docs/IDEA_SLATE.md`, four of
which are game/social rather than RWA infrastructure — a lane the public gallery
under-serves.

One research finding relevant to that choice: the sister Open House event in NYC
was won by Tilt Protocol, Fangorn and EqualFi. None introduced a new primitive.
EqualFi's stated differentiator was nine index tokens **deployed** on Robinhood
Chain testnet during the window.

No product code has been written for any alternative. The decision is open.

### 7.1 Three specific questions for you

Answering these is worth more to the team right now than another code review.

1. **Was Jayo killed prematurely?** (§6.1, kill 2.) It is the only one of the
   four killed by argument rather than measurement, and it originated with the
   non-technical teammate, whose product instincts have so far been better than
   mine. The design is intact in `docs/JAYO_DESIGN.md` / `docs/PROJECT_PLAN.md`.
   If the adversarial critique was over-weighted, that is recoverable in a day.

2. **Finish or pivot?** ~12 days. The engine is roughly 60% of a submission
   (contracts and tests done; deployment, fork tests, SDK, UI, docs not started)
   and is certain to finish but scores low on Innovation. The alternatives score
   higher on Innovation and Memorability but start from zero contract code, and
   two would need their riskiest subsystem proven in the first 48 hours.

3. **Is the churn itself now the biggest risk?** Four abandoned directions in two
   days has cost more than any single wrong choice would have. There is an
   argument that committing to *anything* today and shipping it beats another
   round of selection. If you agree, say which one and the team will build it
   without further relitigation — including if the answer is "finish what you
   already have."

Note on process, so you can calibrate: an earlier round of this analysis was run
as a large parallel agent fan-out, was interrupted mid-run for cost, and one
completed agent's output was left unread on disk until the user asked about it.
It contained the strongest critique produced in the whole session. Subsequent
runs assign cheaper models to mechanical checks and reserve the expensive ones
for genuinely hard reasoning.

---

## 8. Still not done, unchanged from your review

Fork tests, any deployment, contract addresses, SDK, demo UI, `ARCHITECTURE.md`,
`THREAT_MODEL.md`, `DEPLOYMENTS.md`, `DEMO_SCRIPT.md`, `SUBMISSION_COPY.md`.
No static analysis — Slither is not installed in this environment. No invariant
tests; two fuzz tests exist. `ReferenceVault` remains a developer example with no
depositor share accounting, and its test says so.
