# Assessment: "24/7 intent, 24/5 safe settlement"

**Status: ASSESSMENT ONLY. Nothing implemented. No code written for this.**
**Date:** 2026-09-20

Evaluates the proposal: let users submit Stock Token ↔ USDG orders at any time;
execute immediately when the reference is valid; queue when it is stale, paused
or mid-corporate-action; settle after reopening only within the user's signed
limit and the current multiplier policy.

---

## 1. Why this is worth assessing

`docs/PHASE0_EVIDENCE.md` §9 establishes, from live mainnet reads, that every
Robinhood Stock Token feed is currently 36–45 h old against a published 24 h
heartbeat, while crypto feeds are fresh. §9.1 establishes that HookFence as
currently configured would refuse settlement for ~2.5 days a week.

So the plain gateway has a real problem: **its correct behaviour is to refuse,
and refusing 35% of the week is not a product.** This proposal converts the
refusal into a deferral, which is the difference between a circuit breaker and
something a user would choose to use.

It also reframes the pitch from "we reject unsafe swaps" (contested — see
§6 of the evidence report) to "Stock Token users can express orders 24/7 without
settling against stale 24/5 reference data" (not observed in any of the three
verified competitors).

---

## 2. What is reusable

Substantial. Roughly 70% of the existing work carries over unchanged.

| Component | Reuse | Notes |
|---|---|---|
| `StockTokenReferencePolicy` | **As-is** | Already returns a floor and fails closed with typed errors. The queue needs exactly this, called at release time instead of submit time. |
| `IExecutionPolicy` / evidence struct | **As-is** | — |
| `V4ExactInputAdapter` | **As-is** | Route allowlist, narrow surface, no arbitrary call. Unchanged. |
| `ExecutionGateway._settle` internals | **Mostly** | Balance snapshots, allowance grant/revoke, recipient delta, refund, instrument re-check all transfer directly. |
| `ExecutionIntent` + EIP-712 | **Extend** | Needs `notBefore`/`expiry` semantics and a queue id. Typehash changes → version bump. |
| Test fixtures, hooks, baseline router | **As-is** | |
| Mocks | **Extend** | `MockAggregatorV3` needs a scripted "market closed then reopens" sequence. |

## 3. What is new

| New contract / change | Est. size | Risk |
|---|---|---|
| `QueuedSettlement` (escrow + queue) | ~250–350 LoC | **High** — custody |
| Cancel path | ~40 LoC | Medium |
| Keeper/release entrypoint | ~80 LoC | Medium |
| Release-time policy revalidation | ~60 LoC | Low (reuses policy) |
| Extended intent + typehash | ~50 LoC | Medium (signature surface) |
| Optional uniform-price batch | ~200 LoC | **High** — defer, see §6 |

---

## 4. Security risks introduced

This is the part that matters, and it is a **material step up in risk**. The
current design's best property is that it custodies nothing: tokens move inside
one atomic transaction or not at all. A queue destroys that property.

1. **Custody.** Queued orders must escrow the Stock Tokens (or hold an
   allowance). The contract now holds user funds across days. Every custody bug
   class becomes live: accounting drift, stuck funds, griefing, admin risk.
   *Mitigation:* escrow per-order in isolated accounting; no pooled balance; a
   user-callable cancel that cannot be blocked by anyone, including the owner.

2. **A corporate action can land while an order is queued.** This is the sharp
   one and it is Stock-Token-specific. If `uiMultiplier` changes during the
   queue, the user's signed limit was expressed against different economics.
   Settling at the old limit is wrong; silently re-scaling it is also wrong
   because it changes what the user agreed to.
   *Mitigation:* bind `uiMultiplier` into the signed intent; if it changes while
   queued, **cancel the order and return funds** rather than reinterpret it.
   Never re-scale a user's limit without a new signature.

3. **Free option / stale-limit problem.** A resting order priced against
   Friday's close is a free option to whoever settles it on Monday if the gap is
   large. This is a real economic issue, not a code issue, and it exists in
   traditional markets too.
   *Mitigation:* short mandatory expiry (hours, not days); the user's signed
   limit must still bind at release; consider requiring the release price to be
   within a band of the submit price or auto-cancelling.

4. **Who releases, and MEV on release.** A keeper chooses when to call. Release
   ordering across many queued orders is extractable.
   *Mitigation:* permissionless release; deterministic eligibility (release
   allowed iff policy passes); the user's floor is enforced regardless of who
   calls, so a keeper cannot profit by choosing a worse moment — only by
   declining to call, which permissionlessness fixes.

5. **Liveness.** If no keeper calls, orders sit until expiry.
   *Mitigation:* user can always self-release or cancel.

6. **Signature surface grows.** New typehash, new replay considerations across
   submit/cancel/release.
   *Mitigation:* same nonce discipline; test domain separation again from
   scratch.

---

## 5. Honest objections to the whole idea

- **It is a limit order with extra conditions.** Resting orders that execute
  when a price condition is met are one of the oldest ideas in the space. The
  Stock-Token-specific parts (multiplier binding, oracle pause, market-hours
  awareness) are the new bit; the queue is not.
- **The 24/5 gap may be partly an artifact of a young chain.** The feeds *may*
  tighten. Our evidence is a single Sunday observation. **Before committing,
  observe across at least one full week**, which costs nothing —
  `scripts/observe-live-feeds.sh` already exists and can be run on a schedule.
- **Users may not want deferral.** Someone selling on a Saturday may want out
  *now* at whatever the pool offers, and "your order is queued until Monday" is
  a worse product for them than a completed trade. This needs to be opt-in, and
  it weakens the "safety" framing into a "choice" framing.
- **Custody risk may exceed the benefit** for a hackathon deliverable judged on
  smart contract quality. A contract holding funds for days, written in ~10
  days, is a larger attack surface than one that holds nothing.

---

## 6. Time estimate

Against the **2026-10-04 15:59 UTC** deadline (~14 days).

| Scope | Estimate | Verdict |
|---|---|---|
| Core queue: escrow, submit, cancel, permissionless release, multiplier binding, revalidation | 3–4 days | Feasible |
| Security tests for the above (custody invariants, cancel-always-works, corporate-action-cancels) | 2 days | Necessary, not optional |
| Fork tests + testnet deployment | 1–2 days | Already planned |
| SDK + demo covering both paths | 2 days | Already planned |
| Docs, submission, video | 1 day | Already planned |
| **Uniform-price batch auction** | +3 days | **Recommend dropping.** Highest complexity, lowest marginal credibility, and it is where a subtle bug would do the most damage. |

Leaves ~2 days of slack without the batch auction. Tight but workable.

---

## 7. Recommendation

**Conditional yes, without the batch auction, and only after a week of feed
observation.**

Reasoning:

1. It solves a problem we have *measured on mainnet*, not hypothesised.
2. It fixes a genuine defect in the current design (§9.1 of the evidence report)
   rather than adding a feature on top of a working thing.
3. It moves the claim off contested ground (on-chain enforcement — three
   competitors) onto ground that appears unoccupied (market-hours-aware
   settlement for tokenized equities).
4. It reuses ~70% of existing, tested work.

The conditions matter:

- **Drop the batch auction.** Complexity and custody risk are not worth it here.
- **Run `scripts/observe-live-feeds.sh` daily for a week first.** If equity
  feeds turn out to be fresh Mon–Fri and only stale at weekends, that is a
  clean, defensible story. If they are erratically stale mid-week too, the
  framing changes and we should know before building.
- **Keep the immediate path as the default.** Queuing is the fallback when the
  reference is unavailable, not the main flow. The atomic no-custody path stays
  the primary product.
- **Never re-scale a signed limit across a corporate action.** Cancel instead.

If the week of observation contradicts the Sunday reading, this proposal should
be dropped and the project should fall back to hardening the existing gateway.

**Nothing here is built. Awaiting decision.**
