# Hackathon Requirements — verified facts

**Event:** Arbitrum Open House Singapore: Online Buildathon
**Source:** <https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon>
**Accessed:** 2026-09-20 (logged out, public page, read directly from the rendered DOM)

Everything below was read off the live page on the access date. Where this
document disagrees with the original project brief, this document wins and the
correction is called out explicitly.

## 1. Qualification

> "Your project must be deployed on an Arbitrum chain to qualify. For example:
> Arbitrum Sepolia, Arbitrum One, Robinhood Chain, or others."

Robinhood Chain is explicitly named. See `docs/DEPLOYMENTS.md` for what we
actually deployed and where.

## 2. Judging criteria (verbatim, all tracks)

1. **Smart contract quality** — code following best practices, structured
   logically and efficiently, with minimal security vulnerabilities
2. **Product-Market Fit** — projects with clear potential to attract and retain users
3. **Innovation and Creativity** — original approaches that push boundaries
4. **Real Problem Solving** — applications that address genuine market needs

> "Extra consideration is given to projects integrating Paxos' USDG stablecoin."
> (<https://docs.paxos.com/guides/stablecoin/usdg>)

## 3. Prizes

| Track | Pool | 1st | 2nd | 3rd |
|---|---|---|---|---|
| Overall Prize | 70,000 USDC | 40,000 | 20,000 | 10,000 |
| Promising Products Track | 15,000 USDC | 7,000 | 5,000 | 3,000 |
| Grants | up to 30,000 USDC | milestone-based, discretionary | | |

Stated reservations, on both the Overall and Promising Products tracks:

- "At minimum, 1 of 3 prizes is reserved for a project building on Robinhood Chain"
- "At minimum, 1 of 3 prizes is reserved for a project building on Arbitrum"
- Overall track adds: "All prizes are subject to development-tied milestones."

Top three teams also receive a place at the in-person Founder House in Singapore.

## 4. Schedule — and the timezone question, resolved

The Schedule tab renders:

| Phase | Displayed window |
|---|---|
| Registration | Jul 30, 2026 01:01 – **Oct 3, 2026 01:01** |
| Submission | Sep 14, 2026 01:01 – **Oct 4, 2026 23:59** |
| Reward Announcement | Oct 12, 2026 14:00 |

**Correction to the original brief.** The brief recorded the submission close as
"4 October 2026 at 15:59" with an unknown timezone. That is the same instant
expressed in UTC; the page renders in *viewer-local* time.

Derivation, done on the page rather than assumed:

- Browser local time at read: `Sun Sep 20 2026 14:08:34 GMT+0800`
- Live registration countdown at that moment: `12D 10H 53M`
- 2026-09-20 14:08:34 +08:00 plus 12d 10h 53m = **2026-10-03 01:01 +08:00**
- That matches the *displayed* registration end exactly, so displayed times are
  in the viewer's local timezone.

Therefore, converting the displayed submission close from UTC+8:

> **Submission closes 2026-10-04 15:59 UTC** (= 2026-10-04 23:59 UTC+8
> = 2026-10-04 23:59 Singapore time, since SGT is UTC+8).

Because the organiser is Singapore-based and SGT is UTC+8, the practical
deadline for a Singapore participant is 23:59 local on 4 October 2026.

**Residual risk:** this is a derivation from a client-rendered countdown, not an
organiser statement. A human should still confirm it in the logged-in dashboard.
Tracked in `MANUAL_ACTIONS.md`. The derivation is self-consistent and we treat
the *earlier* of the two readings (15:59 UTC) as the working deadline.

## 5. Official resources that matter to this project

| Resource | URL |
|---|---|
| Robinhood Chain docs | <https://docs.robinhood.com/chain/> |
| Robinhood Chain testnet faucet | <https://faucet.testnet.chain.robinhood.com/> |
| Paxos USDG | <https://docs.paxos.com/guides/stablecoin/usdg> |
| Terms & Conditions (PDF) | <https://openhouse.arbitrum.io/singapore_version_open_house_buildathon_terms___conditions.pdf> |

## 6. Competitive context (Project Gallery, same access date)

Read from the public gallery. Listed so our novelty claims stay honest — several
entries are in the tokenized-equity risk space:

| Project | Self-description (truncated as shown in the gallery) |
|---|---|
| RWA Guard | "One call that answers: is this token safe to ac…" |
| Parity | "Risk intelligence for Robinhood Stock Tokens…" |
| Vigil | "Session-aware collateral risk layer for tokenized e…" |
| Undertow | "On-chain risk scanner using real CME SPAN math…" |
| NERON & LYRA | "AI-guarded DeFi on Robinhood Chain…" |
| Hashling | "Every Robinhood Chain token on one board, ~475k…" |
| PulsarFi | "1:1 Asset-Backed Indonesian Equity…" |

### 6.1 CORRECTION (2026-09-20)

An earlier version of this section claimed these entries were "advisory /
scoring / scanning" products and that HookFence was distinct in *enforcing*
on-chain. **That claim was false.** It was inferred from truncated gallery
blurbs and never verified. It is withdrawn.

Project pages were then fetched and read in full on 2026-09-20:

| Project | Verified enforcement claim (their words, abridged) |
|---|---|
| **ArbiGuard** | "enforces protocol-signed risk policies, and trips a hysteresis circuit breaker"; on-chain Stylus risk engine; EIP-712 signed policy; "detect an attack and stop it in the same block" |
| **RWA.Index** | ERC-4626 vault: "Each trade is checked against on-chain guardrails: per-trade size cap, slippage floor (2%), drift-improvement requirement, cash floor, **oracle staleness, pause flag**. Any failure reverts." |
| **Mandate** | ERC-8226: "five enforcement layers checked atomically by the smart contract before value moves"; "the contract reverts. Not the backend code. The EVM." |

On-chain policy enforcement for tokenized equities is a **contested space with
at least three entrants**. RWA.Index in particular already enforces oracle
staleness and a pause flag on Robinhood Chain tokenized stocks — a subset of
`StockTokenReferencePolicy`.

We therefore make **no claim to novelty of mechanism**. See
`docs/PHASE0_EVIDENCE.md` §6 and §8 for the full record and for the narrower
areas that remain, as far as verified, unaddressed.

## 7. What still needs a logged-in human

See `MANUAL_ACTIONS.md`. Summary: confirm the deadline timezone in the
dashboard, confirm the submission form fields, register the team, submit.
