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

### 6.1 What these killed

M6 and M7 each invalidated a product direction that had been proposed and, in one
case, written up as a design doc:

- A **market-hours dynamic-fee hook** was proposed as differentiated. M6 shows
  94% of equity pools are already hooked with 750 distinct implementations,
  several carrying the exact permission set for a custom-curve no-LP venue. Dead.
- A **corporate-action arbitrage** thesis was proposed. M7 shows the effect is
  2–14× smaller than ordinary daily noise and not separable at feed granularity.
  Dead.

Two earlier directions (dividend-yield stripping; a transferable portfolio NFT
with a return leaderboard) died to yield thinness and to an incentive critique
respectively. All four are logged with cause in `FINDINGS_LOG.md`.

### 6.2 A methodological error worth recording

Two of my own measurements were initially wrong and self-corrected:

- A first pool query reported "0 swaps ever" because RPC errors were being
  swallowed. Re-run with error surfacing: the chain is extremely active.
- Two `topics[0]` vs `topics[1]` indexing bugs conflated the event signature with
  the pool id.

All figures above come from the corrected queries.

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

---

## 8. Still not done, unchanged from your review

Fork tests, any deployment, contract addresses, SDK, demo UI, `ARCHITECTURE.md`,
`THREAT_MODEL.md`, `DEPLOYMENTS.md`, `DEMO_SCRIPT.md`, `SUBMISSION_COPY.md`.
No static analysis — Slither is not installed in this environment. No invariant
tests; two fuzz tests exist. `ReferenceVault` remains a developer example with no
depositor share accounting, and its test says so.
