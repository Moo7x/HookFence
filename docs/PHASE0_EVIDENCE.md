# Phase 0 — evidence report (provenance-labelled)

**Repository:** `C:\Users\Mega-PC\Desktop\singapore_hack`
**Remote:** <https://github.com/Moo7x/HookFence.git> (commits local; not yet pushed)
**Date:** 2026-09-20
**Commits:** `e183ba7` (harness + A/B/C/D), `6ffd0f0` (policy-beyond-floor + conclusion),
`976ec9a` (freeze)

> **Superseded in part.** An independent review of `976ec9a` reproduced two real
> defects, both now fixed on branch `fix/phase0-review-defects`. See
> `docs/REVIEW_REPAIRS.md`. The A/B/C/D result below is unchanged by those
> repairs; the gas overhead moved from +104,377 to +111,527.

This document answers the specific questions asked in review. Companion analysis
is in `BASELINE_RESULTS.md`; this file is the raw evidence and provenance.

---

## 0. Corrections to earlier statements

Four claims were made in conversation that the evidence does not support. They
are withdrawn here and were never in the committed documents, except as noted.

| Claim made | Status | Correct statement |
|---|---|---|
| "minAmountOut does not protect you" | **Withdrawn** | It protects correctly against the number supplied. The failure mode is that the number is computed before inclusion and can be stale by then. |
| "Same minimum, one settles and one reverts" | **Withdrawn — impossible** | Given an identical numeric minimum, both produce an identical decision, and `test_Phase0_FourPathComparison` asserts exactly that. The divergent test uses B = quote-time floor, C = re-derived floor. Different numbers. |
| "The pool robs the user" | **Withdrawn** | A reference price moving during mempool latency is not theft and implies no malicious behaviour. Correct phrasing: the fill is below the *current* reference, while satisfying a minimum derived earlier. |
| "We are the only project enforcing on-chain" | **Withdrawn — false** | Verified false. See §6. `docs/HACKATHON_REQUIREMENTS.md` §6 has been corrected. |

---

## 1. Provenance: what is live, forked, or mocked

**All executable tests to date are 100% MOCKED. There is no fork test and no
deployment yet.** This is the honest state.

| Element | Provenance | Detail |
|---|---|---|
| Uniswap v4 `PoolManager` | **Real code, local deploy** | `lib/v4-core` @ solc 0.8.26, deployed fresh in `setUp()`. Real v4 swap accounting, not simulated AMM math. |
| Stock Token | **MOCK** | `MockStockToken.sol`. Surface copied from live AAPL (§2). |
| USDG | **MOCK** | `MockUSDG.sol`, 6 decimals. |
| Chainlink feeds | **MOCK** | `MockAggregatorV3.sol`, 8 decimals. |
| Hooks | **MOCK / our own fixtures** | `HonestHook`, `ContextSensitiveHook`. |
| Pool liquidity | **MOCK** | Seeded locally, full-range. |
| Fork tests | **NONE YET** | Not written. Next step. |
| Testnet deployment | **NONE YET** | Blocked on faucet (`MANUAL_ACTIONS.md` #1). |
| Contract addresses | **NONE YET** | Nothing deployed anywhere. |

**Live mainnet reads (read-only `eth_call`, no transactions):** used to *derive
the mock parameters* and recorded in §2 and §5. Those are real. The tests
themselves do not touch mainnet.

---

## 2. Live values read from Robinhood Chain mainnet (chainId 4663)

Read 2026-09-20 via public RPC `https://rpc.mainnet.chain.robinhood.com`.

| Contract | Address | Read | Value |
|---|---|---|---|
| AAPL Stock Token | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `decimals()` | 18 |
| | | `uiMultiplier()` | `1000566080061092436` |
| | | `newUIMultiplier()` | `1000566080061092436` |
| | | `effectiveAt()` | `1786720366` |
| | | `oraclePaused()` | `false` |
| | | `totalSupply()` | `16314943355880000000000` |
| | | `totalSupplyUI()` | `16324178920011616183212` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `decimals()` | **6** |
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | published | Uniswap docs, chain 4663 |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | code present | mainnet **and** testnet |

Chainlink proxies (from `feeds-robinhood-mainnet.json`, all 8 decimals /
86400s heartbeat): AAPL/USD `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`,
USDG/USD `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`.

**Negative findings (verified, and they constrain the plan):**

- On Robinhood Chain **testnet (46630)**, `eth_getCode` at the *mainnet* USDG,
  Stock Token and Uniswap v4 addresses returns empty, while Permit2 and L2 WETH
  *are* present at their documented testnet addresses. **Stated precisely:** this
  proves those specific addresses are empty on testnet, not that the network has
  no such deployments anywhere — testnet deployments may live at different
  addresses. An earlier version overstated this. Verifying testnet registries and
  documentation is still outstanding.
- **No Chainlink L2 Sequencer Uptime Feed is published for Robinhood Chain.**
  Zero matches for `sequencer|uptime` in the feed directory. The policy's
  sequencer check is therefore optional and disabled by default rather than
  pointed at a fabricated address.

---

## 3. Which tests ran

```
forge test --match-path "test/spike/*" -vv
```

18 tests, 18 passed, 0 failed. Toolchain: `forge 1.8.3` (`cae51ad`), solc
0.8.26, `evm_version = cancun`, `via_ir = true`, optimizer 200 runs.

| Suite | Tests | File |
|---|---|---|
| Smoke (harness validity) | 3 | `test/spike/Smoke.t.sol` |
| A/B/C/D + contexts + gas | 4 | `test/spike/BaselineComparison.t.sol` |
| Policy beyond the floor | 11 | `test/spike/PolicyBeyondFloor.t.sol` |

---

## 4. A/B/C/D result

Identical starting state via `vm.snapshotState`/`vm.revertToState`. Mined
context `tx.gasprice = 2 gwei`. Trade 10 Stock Tokens. Fixture prices
AAPL $255.00, USDG $1.00. Permitted shortfall 50 bps. Pool fee 30 bps.

Reference value of the trade: **2550.000000 USDG**.

| | Path | Minimum enforced | Result | Output |
|---|---|---|---|---|
| A | Ordinary router, quote-derived min (2% slippage) | 2490.882147 | SETTLED | 2511.215880 |
| B | Ordinary router, **oracle floor** | 2537.250000 | REVERTED | — |
| C | HookFence, full policy | 2537.250000 | REVERTED | — |
| D | HookFence, honest-hook control | 2537.250000 | SETTLED | 2541.716477 |

**B and C enforced the identical floor `2537250000` and rejected the identical
fill `2511215880`.** Asserted in the test:

```solidity
assertEq(b.enforcedMin, c.enforcedMin, "B and C must enforce an identical floor");
```

Decoded revert data (`forge test --match-test test_Phase0_FourPathComparison -vvvv`):

```
B: InsufficientOutput(2511215880, 2537250000)     // BaselineOracleRouter
C: OutputBelowFloor(2511215880, 2537250000)       // ExecutionGateway
```

Raw artifact: `contracts/reports/phase0-baselines.json`.

### 4.1 Interpretation

HookFence provides **no advantage over baseline B on output enforcement**. Both
reject the same fill using the same number. The only genuine failure is path A,
and what fails there is the *quote-derived* minimum, not the router mechanism.

---

## 5. Where C differs from B — and how B is modelled

**How B is modelled, stated explicitly because it determines whether the
comparison is fair.** `BaselineOracleRouter`'s only safety parameter is
`minAmountOut`, a `uint256`. A caller derives it from the feeds *before*
sending. The tests therefore compute B's floor at quote time and let state
change before inclusion. C re-derives at settlement.

These are **different numbers**, not the same number behaving differently.

| # | Scenario | B | C | Test |
|---|---|---|---|---|
| 1 | Below-floor fill | REJECT | REJECT | `test_Equal_BothRejectBelowFloorFill` |
| 2 | Honest fill | SETTLE | SETTLE | `test_Equal_BothAcceptHonestFill` |
| 3 | Reference moved before inclusion | SETTLE | REJECT | `test_OnlyC_ReferencePriceMovedBeforeInclusion` |
| 4 | Feed stale | SETTLE | REJECT | `test_OnlyC_StaleFeed` |
| 5 | `oraclePaused()` true | SETTLE | REJECT | `test_OnlyC_IssuerOraclePaused` |
| 6 | Corporate action pending | SETTLE | REJECT | `test_OnlyC_CorporateActionPending` |
| 7 | Adapter misreports output | SETTLE | REJECT | `test_OnlyC_AdapterMisreportsOutput` |
| 8 | Intent replayed | n/a | REJECT | `test_OnlyC_IntentCannotBeReplayed` |
| 9 | Intent expired | n/a | REJECT | `test_OnlyC_ExpiredIntentRejected` |
| 10 | Policy version changed mid-flight | n/a | REJECT | `test_OnlyC_PolicyVersionMismatchRejected` |
| 11 | Look-alike token, same ticker | n/a | REJECT | `test_OnlyC_LookalikeTokenRejected` |

Scenario 3 numbers:

```
floor computed at quote time : 2537.250000 USDG
floor correct at settlement  : 2790.975000 USDG   (reference +10%)
pool pays                    : 2541.716477 USDG
B SETTLES  (2541.72 >= its earlier 2537.25)
C REJECTS  (2541.72 <  current 2790.98)
```

Honest reading: rows 3–6 are all instances of one property — *the floor and the
instrument checks are evaluated at settlement rather than supplied in advance*.
Rows 8–11 have no baseline-B analogue because a router has no concept of an
authorised intent. Row 7 is defence-in-depth against an allowlisted-but-broken
adapter.

**This is established smart-contract engineering, not a new primitive.** The
contribution is the composition and its application to Stock Tokens, not the
technique.

---

## 6. Execution contexts recorded

`test_Phase0_RecordsQuoteAndMinedContexts`:

| Context | `tx.gasprice` | Extracted | Amount |
|---|---|---|---|
| Quote (`eth_call`, no gas price) | 0 | no | 0 |
| Mined | 2,000,000,000 | yes | 30.500597 USDG |

**We do not claim `eth_call` is inherently detectable.**
`test_Phase0_AdversarialHook_IsDefeatedBy_RealisticQuoteContext` proves the
opposite about our own fixture: a quote with `gasPrice = 2 gwei` returns
2511.215880 — it already sees the extraction. The discriminator is a
*default-path* weakness only.

---

## 7. Gas

`test_Phase0_GasOverheadVersusBaseline`, successful settlement, honest pool:

| Path | Gas |
|---|---|
| B — router + floor | 237,333 |
| C — HookFence full policy | 341,710 |
| Overhead | **+104,377 (+44%)** |

Artifact: `contracts/reports/gas-comparison.json`.

---

## 8. Competitive landscape — correction

The earlier claim that competing gallery projects are "all scanners" was
**false** and is withdrawn. Verified by fetching the project pages on
2026-09-20:

| Project | Enforcement claim (their words, abridged) |
|---|---|
| **ArbiGuard** | "enforces protocol-signed risk policies, and trips a hysteresis circuit breaker"; on-chain Stylus risk engine; EIP-712 signed policy; "detect an attack and stop it in the same block" |
| **RWA.Index** | ERC-4626 vault; "Each trade is checked against on-chain guardrails: per-trade size cap, slippage floor (2%), drift-improvement requirement, cash floor, **oracle staleness, pause flag**. Any failure reverts." |
| **Mandate** | ERC-8226; "five enforcement layers checked atomically by the smart contract before value moves"; named custom errors; "the contract reverts. Not the backend code. The EVM." |

**Direct implication for HookFence:** RWA.Index already enforces oracle
staleness and a pause flag on Robinhood Chain tokenized stocks, inside a vault.
That is a subset of `StockTokenReferencePolicy`. On-chain policy enforcement for
tokenized equities is a **contested space with at least three entrants**, and our
innovation claim cannot rest on the mechanism.

What remains, as far as verified, unaddressed by all three:

- ERC-8056 `uiMultiplier` double-count handling and corporate-action timing
  windows (none of the three mention the multiplier at all)
- The 24/5 feed vs 24/7 pool market-hours gap (§9)
- Reusability across integrators rather than being internal to one vault

This is a narrower differentiation than previously claimed and is stated as such.

---

## 9. Live finding: every Stock Token feed is currently past its own heartbeat

Read from mainnet on **Sunday 2026-09-20 09:09:51 UTC**. Reproduce with
`./scripts/observe-live-feeds.sh`; artifact
`contracts/reports/live-feeds-1789895391.json`.

| Feed | Class | Price | Last update (UTC) | Age | vs 86400s heartbeat |
|---|---|---|---|---|---|
| AAPL/USD | stock | $335.38 | Fri Sep 18 15:11 | 42.0 h | **STALE (1.75×)** |
| NVDA/USD | stock | $222.45 | Fri Sep 18 19:55 | 37.2 h | **STALE** |
| TSLA/USD | stock | $363.80 | Fri Sep 18 19:48 | 37.4 h | **STALE** |
| SPY/USD | stock | $761.55 | Fri Sep 18 12:22 | 44.8 h | **STALE (1.87×)** |
| MSFT/USD | stock | $495.82 | Fri Sep 18 20:41 | 36.5 h | **STALE** |
| USDG/USD | crypto | $1.00 | Sat Sep 19 15:35 | 17.6 h | fresh |
| ETH/USD | crypto | $2575.14 | Sun Sep 20 05:24 | 3.8 h | fresh |

Every equity feed exceeds its published 24 h heartbeat; both crypto feeds are
within it. This is consistent with Robinhood's documentation that "Stock feeds
update 24/5, following market hours."

### 9.1 What this does and does not imply — CORRECTED

An earlier version of this section called this "a defect in HookFence" and claimed
the gateway "would refuse ~2.5 days a week / ~35% of the week". **Both statements
are withdrawn.**

- **Rejecting a stale price is correct behaviour** for a policy that requires a
  fresh reference. It is a service-*availability* constraint, not broken code. It
  becomes a product defect only if the product promises execution during that
  window. Raising the staleness threshold would not manufacture a fresh price.
- **The 2.5-days / 35% figure is unsupported.** A single Sunday observation cannot
  measure recurring weekly downtime, and a feed's *age at observation* is not the
  *duration* for which its age has exceeded the threshold.

What the observation does support, precisely: at one timestamped moment
(2026-09-20 09:09:51 UTC), all five sampled Stock Token feeds were older than
their published 86400s heartbeat and both sampled crypto feeds were not. That is
consistent with the documented 24/5 update schedule. Establishing a recurring
pattern requires repeated observation; `scripts/observe-live-feeds.sh` produces a
timestamped record each run and can be run alongside development.

The practical open question is calibration: `maxStaleness` per instrument needs to
be chosen against measured feed behaviour rather than copied from the published
heartbeat. That applies equally to any integrator enforcing oracle staleness on
these feeds.

### 9.2 What it does *not* establish

- It does **not** show the weekend pool price is wrong. With the primary market
  closed (mint/burn runs Mon 02:00 → Sat 02:00 CET), the pool may be the only
  venue expressing a price at all. The correct statement is that **no
  authoritative external reference is available**, not that the pool is lying.
- Rejecting on staleness is a **circuit breaker**, not a pricing solution.
  Nobody can know the reopening price. Blocking is safe but it is not a product.

Assessment of a product-shaped response is in `docs/EXTENSION_ASSESSMENT.md`.
No implementation has been started.

---

## 10. Reproducing everything

```bash
cd contracts && forge test --match-path "test/spike/*" -vv
```

```bash
cd contracts && forge test --match-test test_Phase0_FourPathComparison -vvvv
```

```bash
./scripts/observe-live-feeds.sh
```

Artifacts: `contracts/reports/phase0-baselines.json`,
`contracts/reports/gas-comparison.json`, `contracts/reports/live-feeds-*.json`.

---

## 11. Honest status

- Phase 0 ran and produced a result. Output enforcement: **no advantage over a
  correctly configured baseline**, asserted in CI.
- Value beyond baseline exists but reduces to one property (evaluate at
  settlement) plus intent authenticity plus Stock-Token-specific state checks.
- The mechanism is **not novel** and is contested by at least three gallery
  projects, one of which implements a subset of our policy already.
- Everything is mocked. No fork test, no deployment, no addresses.
- A real defect was found in our own staleness calibration (§9.1).

---

## 12. Committed trace artifacts

Saved under `contracts/reports/traces/` so results are inspectable without
re-running:

| File | Contents |
|---|---|
| `full-run.txt` | All 18 spike tests, `-vv`, with console output |
| `abcd-trace.txt` | `test_Phase0_FourPathComparison` at `-vvvv`, full call trace including decoded reverts |
| `policy-beyond-floor.txt` | All 11 B-vs-C divergence scenarios, `-vv` |

Clean-state verification (`forge clean && forge test`): **18 passed, 0 failed,
0 skipped**, three suites.

---

## 13. Repository state at freeze

```
singapore_hack/
├── contracts/
│   ├── src/
│   │   ├── core/ExecutionGateway.sol                 intent auth, settlement, accounting
│   │   ├── policy/StockTokenReferencePolicy.sol      feed validity, units, floor
│   │   ├── adapters/V4ExactInputAdapter.sol          one reviewed v4 exact-input route
│   │   ├── integrations/ReferenceVault.sol           the consuming vault
│   │   ├── interfaces/                               IStockToken, IAggregatorV3,
│   │   │                                             IExecutionPolicy, IExecutionAdapter
│   │   └── mocks/                                    MockStockToken, MockUSDG,
│   │                                                 MockAggregatorV3, MockSequencerUptimeFeed,
│   │                                                 HonestHook, ContextSensitiveHook,
│   │                                                 BaselineOracleRouter, MisreportingAdapter,
│   │                                                 BaseTestHook
│   ├── test/
│   │   ├── spike/       Smoke.t.sol, BaselineComparison.t.sol, PolicyBeyondFloor.t.sol
│   │   └── utils/       HookFenceFixture.sol, TestLiquidityRouter.sol
│   └── reports/         phase0-baselines.json, gas-comparison.json,
│                        live-feeds-<unix>.json, traces/
├── docs/                PHASE0_EVIDENCE.md (this file), BASELINE_RESULTS.md,
│                        HACKATHON_REQUIREMENTS.md, EXTENSION_ASSESSMENT.md
├── scripts/             observe-live-feeds.sh, new-testnet-wallet.sh
├── MANUAL_ACTIONS.md
└── .env.example         (.env is git-ignored; no secrets committed)
```

**Not built:** fork tests, deployment scripts, SDK, demo UI, `ARCHITECTURE.md`,
`THREAT_MODEL.md`, `DEPLOYMENTS.md`, `DEMO_SCRIPT.md`, `SUBMISSION_COPY.md`.

**Frozen pending review.** No further implementation or reframing will proceed
without a decision.
