# Phase 0 — Baseline results and claim validation

**Status:** complete — implementation FROZEN at commit `6ffd0f0`
**Date:** 2026-09-20
**Verdict:** continue as **HookFence**, with a narrowed and corrected claim (§7)

> **Read `docs/PHASE0_EVIDENCE.md` alongside this.** That file carries the raw
> evidence, the mock-vs-fork-vs-live provenance table, real contract addresses,
> a record of four claims made in conversation that this evidence does **not**
> support, and a verified correction to our competitive positioning.
>
> Two things stated up front, because they are the most important and the
> easiest to skim past:
> 1. **Every test here is mocked.** Real `v4-core` PoolManager code, but mock
>    tokens, mock feeds, mock hooks. No fork test. No deployment. No addresses.
> 2. **On output enforcement HookFence has no advantage** over a correctly
>    configured ordinary router, and the mechanism it does use is **not novel** —
>    at least three gallery projects enforce policy on-chain, one of which
>    already implements a subset of our checks.

This document exists to try to *disprove* HookFence's reason to exist, and to
record what survived. Everything below is produced by tests in the repository;
every number is reproducible with the commands in §8.

---

## 1. The claim under test

> A Stock Token → USDG swap settles only when the exact instrument and reference
> data are valid and the actual tokens received satisfy a signed, versioned policy.

The part of that claim most likely to be **false or unremarkable** is the output
enforcement, because Uniswap v4 already enforces a minimum output. So the spike
was built to give the baseline every advantage.

---

## 2. Environment

Deterministic local harness (`test/utils/HookFenceFixture.sol`) on a real
`v4-core` `PoolManager`. Not mocked AMM math — actual v4 swap accounting.

Fixture values are not invented; they were read from **live Robinhood Chain
mainnet (chainId 4663) on 2026-09-20**:

| Property | Live value | Source |
|---|---|---|
| Stock Token decimals | 18 | `AAPL.decimals()` @ `0xaF3D…93f9` |
| `uiMultiplier()` | `1000566080061092436` | same |
| `oraclePaused()` | `false` | same |
| USDG decimals | **6** | `USDG.decimals()` @ `0x5fc5…d168` |
| Feed decimals / heartbeat | 8 / 86400s | Chainlink `feeds-robinhood-mainnet.json` |

The 18-in / 6-out / 8-decimal-feed asymmetry is preserved in the mocks, because
it is what makes the normalisation non-trivial.

**Market setup:** AAPL/USD = $255.00, USDG/USD = $1.00, 0.30% fee tier, full-range
liquidity, trade size 10 Stock Tokens. Permitted shortfall vs reference: 50 bps.

### 2.1 Hook fixtures

Two pools, identical in fee tier, tick spacing, liquidity and **hook permission
flags** (`AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA`). They differ only in hook
behaviour, so a C-vs-D comparison isolates behaviour rather than pool shape.

- `HonestHook` — never extracts, never varies with context.
- `ContextSensitiveHook` — extracts 120 bps of output when `tx.gasprice ≥ 1 gwei`.

### 2.2 Why that discriminator, and what it does *not* prove

Enso documented production pools that behave differently under simulation than
under inclusion, keying on environment values including gas price, `tx.origin`,
`msg.sender`, `block.coinbase` and `block.basefee`
(<https://blog.enso.build/toxic-pools/>). The fixture reproduces that failure
class with one documented discriminator: a naive `eth_call` supplies no gas
price, so `tx.gasprice == 0`.

**We do not claim `eth_call` is inherently detectable. It is not.** The spike
proves the opposite about its own fixture:

`test_Phase0_AdversarialHook_IsDefeatedBy_RealisticQuoteContext`

| Quote taken with | Quoted output |
|---|---|
| `gasPrice = 0` (naive) | 2541.716477 USDG |
| `gasPrice = 2 gwei` (realistic) | 2511.215880 USDG |

A simulator that supplies transaction-like context sees the extraction
immediately. State writes during `eth_call` also execute and are merely
discarded, so a persistent "real settlement" flag would be an unrealistic
fixture and is not used.

The narrower, survivable point: **default quoting paths are distinguishable, so
a quote-derived minimum is not a trustworthy safety bound.** The durable defence
that follows is an *independent reference floor* — which is exactly why baseline
B also defeats this hook, and why HookFence must not claim otherwise.

---

## 3. The four paths

All four run from identical state (`vm.snapshotState` / `vm.revertToState`),
in the mined context (`tx.gasprice = 2 gwei`), against the adversarial pool
except D.

| | Path | Minimum enforced | Result | Output |
|---|---|---|---|---|
| **A** | Ordinary router, quote-derived min, 2% user slippage | 2490.882147 | **SETTLED** | 2511.215880 |
| **B** | Ordinary router, **same oracle floor as HookFence** | 2537.250000 | **REVERTED** | — |
| **C** | HookFence, full policy | 2537.250000 | **REVERTED** | — |
| **D** | HookFence, honest-hook control | 2537.250000 | **SETTLED** | 2541.716477 |

Reference value of 10 Stock Tokens: **2550.000000 USDG**.

Decoded revert data (from `forge test -vvvv`):

```
B: InsufficientOutput(2511215880, 2537250000)     // BaselineOracleRouter
C: OutputBelowFloor(2511215880, 2537250000)       // ExecutionGateway
```

Raw machine-readable results: [`contracts/reports/phase0-baselines.json`](../contracts/reports/phase0-baselines.json).

### 3.1 The uncomfortable finding, stated plainly

**B and C enforce a byte-identical floor (2537250000) and reject a byte-identical
fill (2511215880).**

HookFence does **not** beat a correctly configured oracle-floor router on output
enforcement. It does not invent atomic slippage protection. The test
`test_Phase0_FourPathComparison` asserts `b.enforcedMin == c.enforcedMin` so this
equality is locked into CI and cannot quietly disappear from a later pitch.

Path A is the only genuine failure, and what fails there is the *quote-derived*
minimum, not the router.

---

## 4. Trying to disprove the distinction

If B == C everywhere, HookFence should be abandoned. So the second suite
(`test/spike/PolicyBeyondFloor.t.sol`) hunts for divergence.

### 4.1 How baseline B is modelled, and why it is fair

`BaselineOracleRouter`'s only safety parameter is `minAmountOut`, a `uint256`.
A caller derives that number from the reference feeds **before** sending, because
the interface has nowhere to put anything else. The tests therefore compute B's
floor at quote time and let the world change before inclusion. That is the actual
shape of the integration, not a contrived handicap.

The structural difference:

- **B enforces a number decided earlier, off-chain.**
- **C re-derives the floor, and re-checks instrument state, in the settling block.**

### 4.2 Results

| Scenario | B | C | Test |
|---|---|---|---|
| Below-floor fill | REJECTED | REJECTED | `test_Equal_BothRejectBelowFloorFill` |
| Honest fill | SETTLED | SETTLED | `test_Equal_BothAcceptHonestFill` |
| **Reference price moved before inclusion** | **SETTLED** | REJECTED | `test_OnlyC_ReferencePriceMovedBeforeInclusion` |
| **Stale feed** | **SETTLED** | REJECTED | `test_OnlyC_StaleFeed` |
| **Issuer `oraclePaused()`** | **SETTLED** | REJECTED | `test_OnlyC_IssuerOraclePaused` |
| **Corporate action pending** | **SETTLED** | REJECTED | `test_OnlyC_CorporateActionPending` |
| **Adapter misreports output** | **SETTLED** | REJECTED | `test_OnlyC_AdapterMisreportsOutput` |
| Intent replayed | n/a | REJECTED | `test_OnlyC_IntentCannotBeReplayed` |
| Intent expired | n/a | REJECTED | `test_OnlyC_ExpiredIntentRejected` |
| Policy version changed mid-flight | n/a | REJECTED | `test_OnlyC_PolicyVersionMismatchRejected` |
| Look-alike token (same ticker) | n/a | REJECTED | `test_OnlyC_LookalikeTokenRejected` |

"n/a" means an ordinary router has no such concept at all — there is nothing to
replay, expire or version.

### 4.3 The single most important divergence

`test_OnlyC_ReferencePriceMovedBeforeInclusion` needs **no malicious hook**. The
instrument reprices +10% between quote and inclusion while the AMM has not caught
up:

```
floor computed at quote time : 2537.250000 USDG
floor correct at settlement  : 2790.975000 USDG
pool pays                    : 2541.716477 USDG
B: SETTLED   (2541.72 ≥ its stale 2537.25)
C: REJECTED  (2541.72 <  current 2790.98)
```

B settles ~9% below the *current* reference while satisfying its own safety
check exactly as designed. Latency between an off-chain calculation and
inclusion is sufficient; no toxicity and no malicious actor is required.

**Precise wording matters here, and earlier drafts got it wrong:**

- B is **not** malfunctioning. `minAmountOut` protects correctly against the
  number it was given. The number was simply computed earlier.
- B and C are **not** enforcing "the same minimum". B enforces 2537.250000
  (quote time); C enforces 2790.975000 (settlement time). Given an *identical*
  number they produce an *identical* decision — §3 asserts exactly that.
- The pool is **not** "stealing". A reference price moving during mempool
  latency implies no malicious behaviour by anyone.

The defensible statement is narrow: *a floor evaluated at settlement can differ
from a floor supplied in advance, and only the former reflects the state that
actually settles.* That is established smart-contract engineering — an on-chain
wrapper recomputing a bound is a known pattern, not a new primitive.

### 4.4 The honest counter-argument

A conscientious B integrator *can* re-check staleness, pause state and price
off-chain before signing. Two things remain true even then:

1. The gap between checking and mining is not closed by an off-chain check.
   §4.3 is precisely that gap.
2. Doing so means re-implementing this policy — feed mapping, validity rules,
   pause flag, ERC-8056 timing, 18→8→6 decimal normalisation, the
   "don't re-apply `uiMultiplier`" rule, recipient accounting — in **every**
   integration. That is an integration-cost argument, and it is legitimate, but
   it is not a claim that the checks are impossible elsewhere.

We make the first argument as a security claim and the second as an economic one.
We do not claim novelty for the individual checks.

---

## 5. Cost

`test_Phase0_GasOverheadVersusBaseline`, successful settlement on the honest pool:

| Path | Gas |
|---|---|
| B — ordinary router + floor | 237,333 |
| C — HookFence full policy | 341,710 |
| **Overhead** | **+104,377 (+44%)** |

Raw: [`contracts/reports/gas-comparison.json`](../contracts/reports/gas-comparison.json).

This is a real cost and we report it rather than burying it. On an Arbitrum L2 it
is economically small relative to a multi-thousand-dollar equity trade, but it is
not zero, and for a high-frequency strategy it would matter. The test asserts
`gasC > gasB` so the number stays honest as the code changes.

**HookFence does not recover gas on a rejected trade.** A mined revert costs the
trader gas and returns nothing. There is no insurance, reimbursement or execution
guarantee anywhere in this system.

---

## 6. Known limits of this evidence

- Local harness with mock feeds and mock tokens. Real feed behaviour, real pool
  liquidity and real adversaries are not modelled. Fork tests against Robinhood
  Chain mainnet are the next step.
- One discriminator (`tx.gasprice`) stands in for a documented family of them.
- The adversarial hook is our own fixture. It demonstrates a failure *class*
  reported by Enso on Ethereum and Polygon; it is **not** evidence that this
  attack has occurred on Robinhood Chain.
- 50 bps permitted shortfall against a 30 bps pool fee is a tight margin chosen
  to make the demo legible. Production values need per-instrument calibration.
- `oraclePaused()` is documented by Robinhood as **advisory and not enforced
  on-chain**; a paused oracle may still return a value. We therefore keep
  staleness as the primary guard and treat the flag as an additional fail-closed
  signal, exactly as the docs advise.

---

## 7. Gate decision

The brief set three outcomes.

- **Keep HookFence** — if the full mined-transaction policy and reference
  integration provide useful value beyond quote-derived slippage.
- Rename to *Stock Token Execution Policy Kit* — if output enforcement only
  equals baseline B but the combined policy still reduces integration work.
- Stop — if the ecosystem already implements the same complete policy and the
  reference vault gains nothing.

**Decision: keep HookFence.**

Justification, and the limits of it:

1. C provides value beyond B on six scenarios (§4.2), one of which (§4.3)
   requires no adversary at all and is a pure consequence of enforcing a policy
   in-block rather than passing a precomputed number.
2. The stop condition is not met: `ReferenceVault` integrates in one call and
   would otherwise carry the entire policy itself. **However**, this is now a
   closer call than when first written. Verification on 2026-09-20 found that
   RWA.Index already enforces oracle staleness and a pause flag inside an
   ERC-4626 vault on Robinhood Chain — a subset of this policy, shipped by a
   competitor. The ecosystem does not implement the *complete* policy (no
   competitor mentions ERC-8056 multiplier handling at all), so the kill
   condition is not triggered, but the margin is thinner than claimed.
3. **But the claim must be narrowed.** HookFence does *not* invent slippage
   protection, and §3.1 is now a permanent assertion in the test suite. The
   honest one-line claim is:

   > HookFence enforces a complete Stock Token execution policy — instrument
   > identity, reference validity, issuer pause, corporate-action timing, unit
   > handling, intent authenticity and real recipient accounting — inside the
   > settlement transaction, so that a swap either satisfies all of it or moves
   > no tokens.

   Not: "HookFence protects you from bad fills." A router with the same floor
   does that too.

The name stays because the enforcement mechanism (a gateway that fences
execution) is what is distinctive; the *Policy Kit* framing understates that the
checks run in-block.

---

## 8. Reproducing this

```bash
cd contracts
forge test --match-path "test/spike/*" -vv
```

Individual evidence:

```bash
forge test --match-test test_Phase0_FourPathComparison -vvvv
```

```bash
forge test --match-test test_Phase0_RecordsQuoteAndMinedContexts -vv
```

```bash
forge test --match-path "test/spike/PolicyBeyondFloor.t.sol" -vv
```

Artifacts written: `contracts/reports/phase0-baselines.json`,
`contracts/reports/gas-comparison.json`.

Toolchain: `forge 1.8.3` (`cae51ad`), solc 0.8.26, `evm_version = cancun`,
`via_ir = true`. Uniswap v4 requires transient storage, so Cancun is mandatory —
and is available on Robinhood Chain, where v4 is deployed (§`docs/DEPLOYMENTS.md`).

---

## 9. Recorded execution contexts

`test_Phase0_RecordsQuoteAndMinedContexts`:

| Context | `tx.gasprice` | Hook extracted | Amount |
|---|---|---|---|
| Quote (`eth_call`, no gas price) | 0 | no | 0 |
| Mined transaction | 2,000,000,000 | yes | 30.500597 USDG |

The hook records `tx.gasprice`, `block.basefee`, `tx.origin` and
`block.coinbase` on every swap, so the discriminator is auditable rather than
asserted.
