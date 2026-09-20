# HookFence — Final Team Proposal

**Arbitrum Open House Singapore · 20 September 2026**  
**Decision:** Selected proposal for a focused prototype and team review. Winning potential is unproven; this document is a build recommendation, not a prize prediction. Supersedes the ProofFill recommendation.

## 1. The idea in one sentence

**HookFence is an execution gateway that lets vaults and trading applications enforce Stock Token trading policies in the transaction itself: a swap settles only when the reference data is acceptable and the actual tokens received meet the agreed limits.**

It initially supports Stock Token → USDG swaps through Uniswap v4. It sits in the caller's execution path; it is not another hook attached to somebody else's existing pool.

## 2. Simple example

A vault sells a Stock Token amount independently valued at **1,000 USDG**. These numbers are illustrative, not observed trades.

| Step | Outcome |
|---|---|
| Pool simulation | Quotes 1,000 USDG |
| Ordinary quote-based setting | Allows 2% slippage: minimum 980 USDG |
| Actual execution | Returns 988 USDG after the hook runs |
| Ordinary route | Accepts 988 because it exceeds 980 |
| HookFence policy | Allows 0.5% total shortfall from a valid independent reference: minimum 995 |
| HookFence execution | Reverts the swap; the token transfers roll back |

**The trader still pays transaction gas on a mined revert.** The gateway does not recover gas or guarantee execution.

**Crucial comparison:** an ordinary router supplied with the same 995 minimum also rejects 988. The example proves enforcement, not a new mathematical protection. HookFence's proposed contribution is maintaining and enforcing the full reference-data policy at execution time, consistently across integrations.

## 3. Problem and first customer

Some pools alter behavior between simulation and actual execution. Enso documented this on Ethereum and Polygon, including extraction within permitted slippage and transactions that repeatedly reverted. Those examples establish the failure class; they are not evidence of the same attack on Robinhood Chain. [Enso investigation](https://blog.enso.build/toxic-pools/)

**First customer:** a developer operating a vault or recurring Stock Token trading application who wants a reusable execution policy instead of implementing feed checks, token units and settlement checks separately.

**Adoption hypothesis:** integrating one small gateway reduces integration mistakes and makes a vault's trading rules inspectable and reproducible. This still needs developer feedback. A retail swap interface alone would provide weak differentiation.

## 4. What is distinctive—and what already exists

The proposed distinction is **one reusable, Stock Token-specific execution contract combining reference validity, exact instrument identity, unit handling and final settlement enforcement**, demonstrated against real v4 accounting.

| Existing capability | Implication for our pitch |
|---|---|
| Uniswap v4 already enforces minimum output | Do not claim to invent atomic slippage protection. [Router source](https://raw.githubusercontent.com/Uniswap/v4-periphery/main/src/V4Router.sol) |
| HoodFlow documents reviewed routes, minimum output and oracle-deviation preflights | Our comparison must establish exactly which checks remain enforced inside the mined transaction. Its README alone cannot prove an exclusive gap. [Repository](https://github.com/dereliapps/hoodflow) |
| TARE measures hook extraction | Measurement alone is insufficient differentiation. [Project](https://ethglobal.com/showcase/tare-ozced) |
| Enso describes toxic-pool detection in its own infrastructure | We cannot claim nobody addresses this threat. Our scope is an integrator-controlled onchain policy. [Enso](https://blog.enso.build/toxic-pools/) |

Competition is acceptable. The project must demonstrate useful integration and enforcement beyond a frontend that chooses a tighter minimum. Worldwide novelty and product-market fit are not established.

## 5. MVP mechanism

1. **Authorize an intent.** Bind chain, gateway, owner, recipient, token addresses, exact input, route, minimum output, policy version, nonce and deadline. Use an authenticated caller or EIP-712 signature with replay protection.
2. **Validate the instrument.** Use reviewed token/feed address mappings. A matching ticker is insufficient.
3. **Validate the reference.** Require a positive, sufficiently recent price; reject future timestamps and an active issuer oracle pause. Pin freshness limits per supported feed. Check sequencer status/grace period where a supported uptime source exists.
4. **Handle Stock Token units correctly.** Robinhood's token feed already includes the corporate-action multiplier: do not apply it twice. Normalize token, feed and USDG decimals. [Chainlink integration guidance](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
5. **Calculate the floor before external execution.** For the supported exact-input sell, compute reference output using Stock Token/USD and USDG/USD prices, then apply the permitted total shortfall. Final floor is the greater of this and the user's minimum. Use full-precision arithmetic and documented conservative rounding.
6. **Execute through a narrow adapter.** Permit only the intended input amount and reviewed execution targets. Use reentrancy protection; prohibit arbitrary calls/delegatecalls and unrelated token spending.
7. **Measure settlement.** Check the actual recipient's output balance change, input spent and refunds. Recheck relevant pause/multiplier state for unexpected changes during external execution. Revert the entire operation if any required condition fails.
8. **Produce evidence.** Emit a successful execution receipt with intent, policy, reference round/timestamp and measured amounts.

**Reverts erase events and state written within the reverted transaction.** Failed attempts are shown through transaction status, error data and replay traces—not a fictional permanent rejection event from the reverted gateway.

## 6. Scope and stack

| Component | Scope |
|---|---|
| ExecutionGateway.sol | Intent authorization, policy enforcement, final balance checks |
| ReferencePolicy.sol | Reviewed feed mapping, data validity, unit conversion and output floor |
| V4Adapter.sol | One constrained exact-input swap path |
| Reference vault | One real consumer that executes through the gateway |
| Test fixtures | Honest hook and deliberately context-sensitive adversarial hook |
| Demo interface | Quote, reference, required output, actual output and transaction evidence |
| Tooling | Solidity, Foundry, Uniswap v4, Chainlink Data Feeds, TypeScript/viem |
| Deployment | Robinhood Chain testnet; a mainnet fork for integration evidence |

Start with one Stock Token/USDG pair and one trading direction. Verify available testnet contracts; deploy an explicitly labeled local/testnet v4 fixture when necessary. Do not present mocks as live issuer feeds.

Data Streams are optional. Robinhood documents a mainnet verifier, but report access, exact feed support and testnet availability still require confirmation. The verifier's existence is infrastructure evidence, not proof of customer demand. [Robinhood documentation](https://docs.robinhood.com/chain/data-streams/)

No project token, ML, CUSUM, FHE, custom fee curve or compensation bond is required. AI/DS experience can help analyze test results; it need not become a product feature.

## 7. Constraints and their consequences

| Constraint | Practical consequence |
|---|---|
| Equity references can stop updating outside supported sessions | Oracle-protected execution fails closed when its freshness policy cannot be satisfied. This is not a universal weekend trading solution. |
| Reference price is not an executable quote | Thin liquidity, spread and legitimate premiums can cause rejection. A violation does not prove fraud. |
| The allowed deviation includes multiple costs | It bounds total execution shortfall; it does not separately identify a hook fee. |
| Oracle or configuration can be wrong | Review mappings and policies; bind policy versions so signed intents cannot silently inherit looser rules. |
| Proxy hooks and dependencies can change | Address/codehash screening is supplementary. A proxy codehash alone does not pin its implementation or behavior. |
| Route identity can be rotated | Receipts provide evidence; historical reputation is not a safety guarantee. |
| No funded compensation source | Reject failing trades. Do not promise escrow refunds, insurance or reimbursement. |

## 8. First build milestone: an honest baseline comparison

Build the proof before the full interface. This is part of implementation, not a request for the user to investigate contracts manually. The detailed and corrected procedure now lives in `hookfence-final-build-plan.md`; that file supersedes this section when the two differ.

The adversarial fixture must reproduce a documented difference in quote and transaction context (`tx.gasprice`, `tx.origin`, sender, coinbase or base fee) and record both environments. Do not claim that `eth_call` is inherently detectable, and do not use a fictional persistent “real settlement” flag: `eth_call` runs the same bytecode and discards state changes after execution.

**Compare three paths from equivalent starting states:**

- Quote-derived minimum output.
- Ordinary router with an equally strict oracle-derived minimum output.
- HookFence with its complete execution-time reference policy.

The second baseline must reject the same below-floor fills as HookFence. Then test the integration value: expired reference data between preparation and execution, issuer pause, invalid input price, incorrect units, replayed intent and changed policy version. Show precisely which baseline includes each check.

Also prove legitimate trades succeed, a valid split does not multiply valuation twice, recipient accounting is accurate, and rejected trades roll back token movements. Measure overhead against the baseline.

**Proceed with the full build if:** checks work against v4, the reference policy is correctly implemented, and an integrator can identify a useful reduction in work or risk.

**Reconsider the product scope if:** all demonstrated benefit reduces to choosing a stricter minimum, or existing target integrations already implement the same complete policy. Passing a deliberately weak baseline alone is insufficient evidence.

## 9. Two-minute demonstration

| Time | What judges see |
|---|---|
| 0:00–0:15 | One vault, one Stock Token pair, its approved execution policy |
| 0:15–0:45 | A context-sensitive hook returns a worse fill that passes a loose quote-derived minimum |
| 0:45–1:15 | HookFence rejects that fill; show the equally strict router also rejects it, then demonstrate a reference becoming invalid before execution |
| 1:15–1:45 | Transaction hash/status, decoded failure, restored token balances, successful control trade and receipt |
| 1:45–2:00 | Show the vault integration and explain the reusable policy developers receive |

The technical effort is in correct accounting, execution-time policy enforcement and adversarial evidence. Presentation makes that work understandable; it cannot establish novelty by itself.

## 10. Team execution plan

**Developer A:** gateway, adapter, reference policy, contract tests and fork verification.  
**Developer B:** adversarial fixtures, baseline comparisons, integration SDK, demo UI and evidence capture.

Suggested order: baseline prototype → feed/unit checks → reference vault → deployment → demo. Ask one target developer to review the concrete integration: “Would you use this gateway, or are these checks already covered in your execution contracts?” That is adoption feedback, not permission to begin.

## 11. What we retained from Claude/Qwen

- **Keep:** atomic enforcement, disciplined scope and a timed demo ending with verifiable evidence.
- **Refine:** the atomicity question tests whether this project's onchain component is necessary; it is not a universal rule for rejecting useful offchain products.
- **Narrow:** freshness, pause and units are core guards. Session-based fees and toxic-flow pricing solve different problems and are outside the MVP.
- **Correct:** receipts document outcomes; enforcement lives in executable conditions. Refund guarantees require separately funded commitments.
- **Reject:** a Data Streams verifier proves demand; a statistical detector guarantees innovation; any competitor automatically invalidates the idea.

**Team decision:** build HookFence's bounded proof of concept. The pitch is a reusable execution policy for Stock Token integrations. Its strongest claims must come from the baseline comparison and a working consumer, not from labeling standard slippage checks as new technology.
