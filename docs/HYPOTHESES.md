# Jayo's bets, the evidence for each, and when to drop them

> **Superseded by [GO_NO_GO.md](GO_NO_GO.md): no-go on Jayo as the main product.**

**Updated 2026-09-25.** Each major feature is treated as a hypothesis. "Status"
records what has actually been shown, not what is hoped. The owner's tests with
outsiders (`USER_TESTS.md`) are the missing evidence for most of them.

| # | Hypothesis | Evidence so far | Status | Drop or change it if |
|---|---|---|---|---|
| H1 | People will add money to *someone else's* basket, bought by that basket's plan, rather than send tokens directly | Off-chain precedent: Robinhood custodial gifting (March 2026). On mainnet, adding 100 USDG costs 1.32× the manual route (5 transactions plus knowing the mix), for identical Stock Tokens. Works through the page on testnet (`0x520d8760…02d1`). | **Rejected (2026-09-25).** The owner rejected it outright, and review found no benefit to the person paying; see [GO_NO_GO.md](GO_NO_GO.md) | — |
| H2 | An addition must reach the owner the giver saw, or not happen | V2 let a contribution mined after a hand-over reach the new owner (reproduced). V3 binds `expectedOwner`, and a unit test checks the refusal. Through the page, a stale addition was refused **before any transaction**: the wallet's nonce stayed at 26. | **Confirmed** | never; this is correctness |
| H3 | Starting a basket in kind removes first use's dependence on prices, pools and the keeper | Fork test on real testnet Stock Tokens with every feed stale: passes. Testnet start in kind: 502,813 gas (`0x5eb80fb3…2374`), about half of buying. 225,292 and 288,878 wallets hold testnet TSLA and AMZN. | **Technically confirmed; value to users untested** | outsiders see it as "the same tokens, now harder to reach" |
| H3′ | In-kind import is a cheaper way to *give* Stock Tokens | Mainnet fork: start in kind and hand over costs 790,920 gas; sending both tokens directly costs 205,573 (3.85× cheaper). | **Refuted.** Not claimed. | — |
| H4 | A living basket view, moving only on confirmed state, makes ownership and destination clear | The page shows who receives an addition before signing, a dashed estimate from the contract's own preview, each real step, and actual against estimated amounts after the receipt (`docs/design/after/v3-*.png`). | **Built; comprehension untested** | outsiders cannot answer "who owns these Stock Tokens?" after using it |
| H5 | The public site can stay available with nobody's computer on | Worker keeper built; 6/6 decision tests; ran in Cloudflare's local runtime; the feeds bound the updater key on chain (19 feed tests). | **Built; not deployed** (waits on the owner's Cloudflare login) | it fails, or its key must hold more authority than bounded feed updates |
| H6 | Jayo can run on official Paxos USDG on testnet | Of the 61 testnet pools with official USDG, the only Stock Token pool is a hooked, dynamic-fee TSLA pool with **zero** active liquidity; there is no AMZN pool. | **Refuted on testnet.** Official USDG is shown on the mainnet fork only. | a liquid official-USDG Stock Token pool appears |
| H7 | A plan that splits each payment (not "buy toward target") is understandable | Holdings visibly drift from the plan: #201 holds 93/7 against a 37/63 plan after AMZN was taken out. The page says the plan does not rebalance. M1 does rebalance new money toward targets. | **Open** | outsiders expect additions to restore the mix |

## Against the official judging criteria

The four criteria from the HackQuest page, assessed on evidence, not on effort.

| Criterion | What a judge can check now | Weakest point | Next evidence |
|---|---|---|---|
| **Smart contract quality** | V3: per-position holdings; additions bound to the owner and plan version the giver saw; in-kind intake credits what arrives (fee-on-transfer test); every exit is price-free; empty baskets close; versions 1 and 2 withdraw-only on chain, not stranded. 162 unit tests, 8 testnet fork tests, 3 mainnet fork cost tests, and an **invariant campaign**: five properties held over 25,600 random calls (256 runs × 100) covering every user action. | No external audit. | an outside reviewer's read of `JayoBasket.sol` |
| **Product-market fit** | A live public site, a coherent job ("a basket you keep adding to and hand on"), off-chain precedent. | No outsider has used it yet. The keeper is not deployed, so buying pauses when nobody refreshes. | 2–3 outsider sessions (`USER_TESTS.md`); the keeper deployed |
| **Innovation / creativity** | One transaction by anyone funds a *specific person's own* mix, protected per leg and bound to the owner they saw; the basket then carries its history. Nothing in the 64-project gallery, HoodETF or StonkBrokers does that combination. | Every primitive exists elsewhere, and the claim has to stay that narrow. | outsiders naming a use for it |
| **Real problem solving** | Gifting and building a Stock Token portfolio over time, with no custodian; in-kind start works when prices are paused. | Costs 1.32× (adding) to 2.17× (buy, hand over, exit) the manual route on mainnet, and the testnet pools are tiny. | a user who would pay that overhead for the persistence |
| Paxos USDG (extra consideration) | The mainnet fork uses canonical Paxos USDG. | Not possible live on testnet (H6). | — |
