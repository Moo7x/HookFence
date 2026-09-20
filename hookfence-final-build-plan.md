# HookFence — Final Build Plan

**Hackathon:** Arbitrum Open House Singapore Online Buildathon  
**Date checked:** 20 September 2026  
**Status:** Selected prototype. This is a disciplined build recommendation, not a guarantee of winning.

## 1. Product in one sentence

**HookFence is an onchain execution gateway for Stock Token applications: it allows a swap to settle only when the instrument and reference data are valid and the tokens actually received satisfy the application's signed policy.**

Initial path: one Stock Token → USDG exact-input swap through Uniswap v4 on Robinhood Chain.

## 2. Why this is worth building

Vaults and recurring trading applications need more than a displayed quote. They must correctly handle:

- the exact token and feed addresses;
- feed freshness, positive values and issuer pause state;
- token, oracle and USDG decimal conversion;
- Robinhood Stock Token corporate-action multipliers without applying them twice;
- authorization, nonce, deadline and policy version;
- actual recipient balance change after external execution.

HookFence puts these rules in one reusable contract and evaluates them in the mined transaction. The first customer is a developer building a vault or automated Stock Token strategy who does not want to implement these checks separately.

## 3. Honest novelty claim

Uniswap v4 already supports minimum output. An ordinary router given the same independent, oracle-derived floor will reject the same below-floor fill. HookFence must therefore **not** claim that it invents atomic slippage protection.

The proposed distinction is the complete integration:

1. a Stock Token-specific reference policy;
2. enforcement inside the settlement transaction;
3. a constrained v4 execution adapter;
4. signed, versioned and replay-protected intent;
5. final balance accounting and reproducible evidence;
6. a reference vault showing that another protocol can adopt it.

TARE already measures hook extraction at scale and offers pre-sign advice. Enso already detects toxic liquidity in its routing infrastructure. HookFence is narrower: an integrator-owned settlement policy. These are adjacent systems, not proof that HookFence is unique worldwide.

## 4. Simple example

A vault wants to sell a Stock Token position independently valued at 1,000 USDG.

| Path | Rule | Result when actual output is 988 USDG |
|---|---|---|
| Quote-based route | Quote 1,000; allow 2% slippage; minimum 980 | Settles |
| Ordinary router with independent floor | Minimum 995 | Reverts |
| HookFence | Valid feed and token policy; minimum 995; valid nonce/deadline/policy | Reverts |

This example shows why quote-derived slippage can be weak. It does **not** show HookFence beating an ordinary router configured with the same 995 minimum. The additional value must appear in the complete policy and the ease and safety of integration.

The trader still pays gas for a mined revert. HookFence does not insure the trade or refund gas.

## 5. Phase 0 — prove or narrow the core claim first

Do this before the full UI. Use identical starting state for every path.

### 5.1 Build two hook fixtures

- **Honest hook:** behaves consistently in quotes and transactions.
- **Context-sensitive adversarial hook:** changes behavior using a documented execution-context difference such as `tx.gasprice`, `tx.origin`, `msg.sender`, `block.coinbase` or `block.basefee`.

The adversarial fixture must record the exact context used for the quote and the mined transaction. A flat 4% fee is not sufficient: a strict minimum trivially catches it. Do not claim that `eth_call` is inherently detectable. A simulator can supply transaction-like context, and state writes during `eth_call` are executed but discarded. A special “real settlement” state flag would therefore manufacture an unrealistic result unless its different inputs are explicitly justified.

### 5.2 Compare four paths

| ID | Path | Purpose |
|---|---|---|
| A | Quote-derived minimum with normal user slippage | Reproduce the failure class where a manipulated quote still settles within allowed slippage or repeatedly reverts |
| B | Ordinary v4 router with the same independent oracle floor as HookFence | Strongest fair baseline for output enforcement |
| C | HookFence with the full policy | Test the additional policy and integration value |
| D | Honest-hook control | Prove legitimate execution is not unnecessarily blocked |

### 5.3 Required scenarios

- context-sensitive quote versus execution output;
- stale, future-dated, zero or negative feed value;
- active issuer/oracle pause;
- wrong token/feed mapping;
- token, feed and USDG decimal combinations;
- corporate-action multiplier already included by the feed;
- expired intent, replayed nonce, wrong chain/gateway and changed policy version;
- inaccurate recipient balance or unexpected input spend;
- honest trade at the boundary;
- rollback of all token movements on failure.

### 5.4 Decision rule

Continue as **HookFence** if the implementation proves a useful, reusable mined-transaction policy beyond quote-derived slippage and a reference consumer can integrate it cleanly.

If C only matches B on every meaningful scenario, reposition honestly as **Stock Token Execution Policy Kit**: a reusable implementation of identity, pause, freshness, multiplier, unit, authorization and settlement accounting. Do not pitch toxic-hook protection as the unique invention.

If even that policy duplicates the target ecosystem's complete execution contracts and developers see no integration value, stop this direction. This is a product kill condition, not a request for more ideation before Phase 0.

## 6. MVP contracts

### `ExecutionGateway.sol`

- accepts an authenticated caller or EIP-712 `ExecutionIntent`;
- binds chain ID, gateway, owner, recipient, input/output tokens, exact input, route hash, user minimum, policy ID/version, nonce and deadline;
- consumes nonces and prevents replay;
- calls only an allowlisted adapter and policy;
- grants only the required token allowance and removes residual allowance where applicable;
- uses reentrancy protection;
- checks actual input spent, refunds and recipient output balance change;
- reverts atomically when any rule fails;
- emits a successful receipt with policy and measured settlement data.

### `StockTokenReferencePolicy.sol`

- maps reviewed token addresses to reviewed reference feeds;
- validates positive answer, timestamp, configured freshness and no future timestamp;
- checks the supported issuer/oracle pause signal;
- checks sequencer uptime and grace period only where a valid supported source exists;
- normalizes token, feed and USDG decimals with full-precision arithmetic;
- treats Robinhood's documented multiplier correctly and proves it is not applied twice;
- computes a conservative Stock Token/USDG reference output;
- returns `max(userMinimum, referenceFloor)` using documented rounding;
- versions all material configuration.

### `V4ExactInputAdapter.sol`

- supports one reviewed exact-input route only;
- prohibits arbitrary calls and `delegatecall`;
- validates pool/route parameters;
- exposes no generic token approval surface;
- returns measured amounts for gateway verification.

### `ReferenceVault.sol`

- is the concrete customer, not decorative demo code;
- stores a simple rebalance or exit rule;
- delegates execution to HookFence;
- demonstrates the integration surface and resulting reduction in vault code.

## 7. Data and deployment strategy

1. Start locally with explicit mock Stock Token, USDG and feed contracts whose price, timestamp, pause and multiplier can be controlled.
2. Add a pinned fork for real Uniswap v4 accounting and any reachable mainnet contracts.
3. Deploy the working proof to Robinhood Chain testnet. The hackathon accepts an Arbitrum chain and reserves at least one top-three place for a Robinhood Chain project.
4. Label every mock and fork clearly. Never present simulated issuer data as a live production feed.
5. Use standard Chainlink-style push feeds first. Treat Data Streams as optional until credentials, report access, feed coverage and testnet support are confirmed.
6. Integrate USDG as the settlement asset because it fits the product and receives extra hackathon consideration. Do not add it as a cosmetic transfer.

## 8. Security and correctness requirements

- no private keys, RPC secrets or credentials in source control;
- exact allowances and narrow external-call surface;
- checks-effects-interactions and reentrancy protection;
- EIP-712 domain separation and nonce tests;
- conservative rounding and overflow-safe full-precision math;
- explicit behavior for stale/paused reference data: fail closed;
- configuration changes are versioned, authorized and visible;
- failure evidence comes from transaction status, decoded error and traces because revert events are also reverted;
- no claim that a price deviation proves malicious intent;
- no insurance, reimbursement or guaranteed execution claim.

Use unit tests, fuzz tests and invariants where they protect money-moving logic. Record gas and integration overhead against baseline B.

## 9. Deliverables

- tested Foundry contracts and deployment scripts;
- adversarial and honest fixtures;
- baseline A/B/C/D result table with transaction traces;
- Robinhood Chain testnet deployment addresses;
- small TypeScript/viem SDK;
- focused demo interface;
- reference vault integration;
- architecture diagram and threat model;
- gas/bytecode report;
- README with reproducible commands;
- two-minute demo script and recording checklist;
- concise HackQuest submission copy;
- `MANUAL_ACTIONS.md` containing only actions that require a person.

## 10. Suggested execution order

| Milestone | Output | Gate |
|---|---|---|
| 0. Repository setup | Foundry project, dependencies, CI, threat assumptions | Tests run locally |
| 1. Claim-validation spike | Fixtures and A/B/C/D comparison | Honest conclusion documented |
| 2. Reference policy | Validity, pause, units, multiplier and floor tests | Boundary/fuzz tests pass |
| 3. Gateway and adapter | Authorization and atomic settlement | Security tests and invariants pass |
| 4. Reference vault | Real consumer integration | Integration is smaller/clearer than reimplementation |
| 5. Fork and testnet | Reproducible evidence and deployed contracts | Addresses and transactions recorded |
| 6. UI and submission | Two-minute story, docs and video | Claims match the evidence |

With two developers: Developer A owns policy, gateway, adapter and contract security. Developer B owns fixtures, comparative evidence, SDK, vault, UI and submission assets. Both review Phase 0 before continuing.

## 11. What judges should see

### Smart contract quality

Narrow permissions, versioned policies, precise accounting, replay protection, fuzz/invariant coverage and honest rollback evidence.

### Real problem solving

A concrete vault integrates one policy rather than independently rebuilding identity, oracle, unit and settlement checks.

### Innovation and creativity

The strongest credible claim is the Stock Token-specific policy composed with atomic settlement and an adversarially tested baseline. Do not claim novel slippage math or exclusive discovery of toxic pools.

### Product-market fit

One integration and direct feedback from at least one Stock Token or vault developer. Ask: “Would this gateway remove checks from your execution contract, or do you already enforce the same complete policy?”

## 12. Two-minute demo

| Time | Demonstration |
|---|---|
| 0:00–0:15 | The vault, supported Stock Token/USDG pair and signed policy |
| 0:15–0:40 | Context-sensitive hook gives an attractive quote and a worse execution result under recorded contexts |
| 0:40–1:05 | Path A fails; path B and HookFence both enforce the equal output floor |
| 1:05–1:30 | A stale/paused or incorrectly normalized reference distinguishes the complete HookFence policy from output-only routing |
| 1:30–1:50 | Valid control trade succeeds; show transaction, balances and receipt |
| 1:50–2:00 | Show the reference vault's small integration surface and measured overhead |

## 13. Verified external facts and open items

- TARE is an ETHOnline 2026 Uniswap winner that reports 125,072 measurements across 7,817 pools and uses `anvil_setCode` to compare the hook with an inert stub. Its extension advises before signing and does not broadcast replacement transactions: <https://ethglobal.com/showcase/tare-ozced>
- Enso documented context-sensitive production cases using environment values including gas price, origin, sender, coinbase and base fee: <https://blog.enso.build/toxic-pools/>
- HackQuest currently lists deployment on an Arbitrum chain, smart-contract quality, product-market fit, innovation/creativity and real problem solving as criteria, with extra consideration for USDG: <https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon>
- The page currently shows submission ending **4 October 2026 at 15:59**, but the visible page does not identify the timezone. Confirm the timezone in the logged-in dashboard or with organizers.
- Contract addresses, supported feeds, testnet pool availability, submission fields and the project gallery remain dynamic and must be refreshed during implementation.

## Final decision

Build Phase 0 now. Claude's recommendation to test the strongest baseline before polishing the product is correct. The needed correction is to model the adversarial context faithfully and avoid pretending that a contract possesses a universal “simulation versus real transaction” signal. The result of this spike determines whether the final name remains HookFence or becomes the broader Stock Token Execution Policy Kit.
