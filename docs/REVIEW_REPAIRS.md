# Repairs from the independent review of `976ec9a`

**Branch:** `fix/phase0-review-defects`
**Baseline preserved:** `976ec9a` on `master`, untouched
**Date:** 2026-09-20
**Tests:** 42 passed, 0 failed, 0 skipped from a clean build (was 18)

Scope was limited to correctness repairs and evidence corrections. **No escrow, no
queue, no product reframing.** The product-direction question is deliberately left
open and separate.

---

## 1. Defect 1 — a replacement policy inherited old signatures

**Reproduced by the reviewer.** An intent signed under a 0.5%-shortfall policy
still settled after the administrator swapped in a 5% policy that reported the
same `policyId` and `policyVersion`.

**Root cause.** Both `policyId` and `policyVersion` are values the policy contract
reports *about itself*. Binding them binds a claim, not an identity. Any
replacement can present the same pair.

**Fix** — `src/core/ExecutionGateway.sol`:

- `ExecutionIntent` gains `address policy` and `uint64 configEpoch`.
- `configEpoch` is a gateway-owned monotonic counter, incremented by `setPolicy`
  **and** `setAdapter`.
- `_validate` rejects `PolicyContractMismatch` / `ConfigEpochMismatch`.
- `EXECUTION_INTENT_TYPEHASH` updated accordingly; both events now carry the epoch.

In-flight intents are invalidated by any material configuration change. That is
the intended behaviour: an operator must not be able to loosen terms a user has
already signed.

**Tests** — `test/unit/ReviewRegressions.t.sol`:

| Test | Asserts |
|---|---|
| `test_Regression_ReplacementPolicyCannotReuseOldSignature` | reverts `PolicyContractMismatch`, and first asserts the impersonation is genuine (same id, same version, different address) |
| `test_Regression_AdapterConfigChangeBumpsEpoch` | reverts `ConfigEpochMismatch` |
| `test_Regression_SignatureStillWorksWhenConfigUnchanged` | control — the same signature settles when nothing changed |

The control matters: without it the first two would also pass if signing were
simply broken.

---

## 2. Defect 2 — the post-effective corporate-action buffer was bypassed

**Reproduced by the reviewer.** Rejection one second *before* `effectiveAt`,
acceptance one second *after* it, with the pre-transition feed still inside its
heartbeat and `oraclePaused` false.

**Root cause.** `_checkInstrumentState` returned early when `newUIMultiplier() ==
uiMultiplier()`. Under the ERC-8056 reference implementation `uiMultiplier()`
advances *at* `effectiveAt`, so the two become equal exactly when the transition
fires. The documented post-effective buffer was skipped from that instant onward —
precisely the window where the token has re-based but the feed may still be
publishing pre-transition prices that look valid.

**Fix** — `src/policy/StockTokenReferencePolicy.sol`:

The window is now keyed on `effectiveAt` alone, regardless of whether the change
has already been applied. A scheduled multiplier with no effective timestamp fails
closed. A comment blocks reintroduction of the early return.

**Fixture fix — this is the more important half.** `MockStockToken.uiMultiplier()`
now advances at `effectiveAt`, matching the reference. The old mock only changed
its multiplier when a test called a setter, so it *could not reach* the state that
exposed the bug. A fixture that cannot reach a state cannot test it.

**Tests** — `test/unit/ReviewRegressions.t.sol`:

| Test | Asserts |
|---|---|
| `test_Regression_CorporateActionBufferHoldsAcrossTheTransition` | rejects at `at−`, `at`, `at+1`, `at+59min`, each with the exact `CorporateActionPending` payload |
| `test_Regression_TradingResumesAfterTheBufferElapses` | the instrument is not permanently bricked |
| `test_Regression_MockAdvancesMultiplierAtEffectiveAt` | the fixture really does model ERC-8056 |

---

## 3. A third defect found while fixing the second

Not in the review, found while writing the regression test, and it silently
invalidated our own test.

**Under `via_ir`, a local derived from `block.timestamp` is unsafe to reuse
across a `vm.warp`.**

```solidity
vm.warp(1_000_000);
uint256 at = block.timestamp + 600;   // reads 1_000_600
vm.warp(at);                          // -> 1_000_600   correct
vm.warp(at + 1);                      // -> 1_001_201   NOT 1_000_601
```

Not a compiler bug: `TIMESTAMP` is genuinely constant within a transaction, so the
Yul optimiser may rematerialise `block.timestamp + 600` at each use. `vm.warp`
breaks that invariant from outside the EVM. Note the stack slot is fine —
`console2.log(at)` still prints `1_000_600`; it is the re-derived use in argument
position that drifts.

This made the corporate-action test warp *past* the buffer it was probing, which
looked like a policy defect and was not.

**Repository rule:** never reuse a local derived from `block.timestamp` across a
`vm.warp`. Read it back from an immutable or storage (an external call result
cannot be rematerialised), or warp to absolute literals.

Documented and pinned in `test/unit/CompilerProbe.t.sol`, which asserts the
observed behaviour so a future toolchain change makes it fail loudly.

---

## 4. Evidence corrections

Each numbered item from the review:

| # | Issue | Resolution |
|---|---|---|
| 1 | "Weekend rejection is a defect" overstated | **Accepted.** Rejecting stale prices is correct behaviour for a fresh-reference policy. It is an availability constraint, and becomes a product defect only if the product promises execution in that window. Corrected in `PHASE0_EVIDENCE.md` §9. |
| 2 | "2.5 days / 35% of every week" unsupported | **Accepted and withdrawn.** One Sunday observation cannot measure recurring downtime, and feed *age* at observation is not the *duration* age has exceeded the threshold. Now stated as a single timestamped observation. |
| 3 | No week-long wait needed before progress | **Accepted.** `EXTENSION_ASSESSMENT.md` no longer gates on seven days of observation; `scripts/observe-live-feeds.sh` runs alongside development. |
| 4 | Misreporting-adapter test logged `B=SETTLED` as a literal | **Fixed.** That test never executed B. Now reports `B=N/A` via a separate `_recordCOnly` helper, as do the four intent-related scenarios that have no baseline-B analogue. |
| 5 | Quote context read after snapshot rollback | **Fixed.** `test_Phase0_RecordsQuoteAndMinedContexts` now reads the hook's context *before* `vm.revertToState`. Previously zero/false were indistinguishable from defaults. |
| 6 | Rejection scenarios caught any revert | **Fixed.** `_runHookFenceDetailed` returns the revert selector; five scenarios now assert the exact expected error (`OutputBelowFloor`, `FeedStale`, `OraclePausedForCorporateAction`, `CorporateActionPending`). An empty revert now fails the test explicitly. |
| 7 | Comments referenced nonexistent test files; no fuzz tests; no signature-path test | **Fixed.** Every `*.t.sol` reference in `src/` now resolves. Added `MultiplierAndUnits.t.sol` (8 tests, 2 fuzz at 512 runs) and `ReferenceVaultIntegration.t.sol` (8 tests). Signature path covered by the three regression tests above. |
| 8 | "Testnet has none" overstated | **Accepted.** Empty code at a mainnet address on testnet proves only that *that address* is empty. Reworded to exactly that claim. |

### Gas benchmark

Now carries an in-code caveat. B executes first and warms storage and account
accesses that C reuses, and the policy is read before timing starts. It shows the
overhead is material and positive; it is **not** a controlled production benchmark.

The number also moved, because the two new checks are not free:

| | Before | After |
|---|---|---|
| Baseline B | 237,333 | 237,333 |
| HookFence C | 341,710 | 348,860 |
| Overhead | +104,377 | **+111,527** |

---

## 5. What did NOT change

The A/B/C/D result is byte-identical after all repairs:

```
A  quote-derived min (2%)    SETTLED  2511215880
B  ordinary router + floor   REVERTED (floor 2537250000)
C  HookFence full policy     REVERTED (floor 2537250000)
D  honest-hook control       SETTLED  2541716477
```

B and C still enforce an identical floor and reject an identical fill.
`assertEq(b.enforcedMin, c.enforcedMin)` still holds. **HookFence still has no
advantage over baseline B on output enforcement**, and the mechanism is still not
novel — ArbiGuard, RWA.Index and Mandate all enforce policy on-chain.

---

## 6. Remaining gaps

Unchanged by this branch, and still open:

- **Everything is mocked.** Real `v4-core` code, but mock tokens, feeds and hooks.
  No fork test, no deployment, no addresses.
- **The ERC-8056 timing model is a model.** `TimedMultiplierToken` follows the
  reference implementation. Actual deployed Robinhood behaviour still needs a
  pinned-fork check against a real Stock Token.
- **No invariant tests.** Two fuzz tests exist; there are no stateful invariants.
- **`ReferenceVault` is a developer example**, not a product: no depositor share
  accounting, owner-only withdrawal. Documented as such in its test.
- **No static analysis run.** Slither is not installed in this environment.
- **The product question is untouched.** These repairs make the implementation
  correct. They do not establish a user-facing advantage, and nothing here should
  be read as claiming they do.
