# Jayo product value reset — 25 September 2026

## Verdict

**Stop pitching third-party contributions as Jayo's main use case.** A contributor gets no asset, return, or ownership. A recipient can instead receive stablecoins or Stock Tokens directly. Repeated gifts may suit a small group, but there is no evidence they support the broad product or podium ambition. The owner immediately rejected this pitch, which is decisive feedback on its clarity and appeal. Do not spend another sprint polishing or extending that story.

The V3 work is still a reusable technical base: isolated per-position holdings, real v4 settlement, reference-price checks, in-kind intake and exit, transferability, tests, fork comparisons, and a public site. Treat the gift flow as an optional capability. Reopen the **user's economic reason to choose Jayo** before choosing more features.

## Three candidate jobs, with a hard test for each

| Candidate job and user gain | Existing alternative / challenge | Evidence required before making it the pitch |
|---|---|---|
| **Self-directed portfolio maintenance:** I set target weights; new deposits buy what is underweight and keep my actual holdings closer to my plan without unnecessary sales. I save repeated manual decisions and trades. | [M1](https://help.m1.com/en/articles/9331916-how-your-funds-are-invested-on-m1) already uses dynamic rebalancing off-chain. [Rico OTFs](https://www.hackquest.io/projects/Rico-OnChain-Funds-OTFs) pitches on-chain managed funds with rebalancing on Robinhood Chain; [HoodETF](https://docs.hoodetf.org/learn/how-it-works) offers shared baskets. Jayo would need a credible *personal, self-directed* advantage. | In a realistic holdings-drift example, show exact trades, fees, gas and post-deposit deviation versus Jayo today and manual swaps. Users must want this enough to pay the overhead. Test whether stale equity feeds or thin pools make it impractical. |
| **Atomic sale/purchase of an exact portfolio:** I sell or buy an existing set of Stock Tokens as one position at a stated price, without executing several pool swaps. | Needs a real counterparty and trustworthy valuation; without bids this is only a listing. [StonkBrokers](https://www.stonkbrokers.io/docs) already trades asset-bearing NFTs on Robinhood Chain, though its product differs. | Prove a concrete trade can settle atomically and delivers a measurable advantage over selling/buying each token through available routes. Show how price, stale feeds, and token composition are bound in the order. Do not claim liquidity or demand without it. |
| **Execution-quality basket purchase:** I choose a mix and Jayo finds an acceptably priced route for each leg, refuses bad fills, and completes all legs together. | [HoodETF](https://docs.hoodetf.org/learn/how-it-works) offers one-click USDG basket entry; ordinary routers can enforce the same reference-derived floors. Jayo's existing fork comparison found identical accepted outputs to direct swaps and higher gas. | Find actual chain cases where route selection or atomic policy produces a better user outcome than a competent router or HoodETF, at quoted sizes. If there is no measurable advantage, reject this as the main pitch. |

**Current ranking:** investigate personal portfolio maintenance first because the owner personally benefits, the existing basket and buy path can be reused, and a quantitative comparison can decide it quickly. This is a *candidate*, not the new approved direction. Atomic portfolio trading is higher risk and should be tested in parallel only with a small feasibility spike. Gift-oriented positioning is rejected.

## Next decision, limited to one day

1. Freeze new gift features and submission polish. Preserve the clean V3 build and document its current deployments; no rollback of working exits.
2. Specify the strongest two user jobs above in one paragraph each. For each, state: **who pays, what they gain, why a wallet/DEX/HoodETF/Rico cannot give the same result as conveniently, and what Jayo costs them**.
3. Run one representative fork calculation for portfolio maintenance and one executable quote/settlement feasibility check for an atomic basket trade. Compare against an ordinary user baseline, including gas and pool impact. Do not build a full interface first.
4. Give the owner a go/no-go recommendation. If neither candidate shows a real advantage, preserve Jayo as a technical portfolio prototype and choose a different product problem. The sunk code is not a reason to keep a weak use case.

## Claim discipline

Rico's HackQuest page documents managed Stock Token funds, rebalancing and USDG entry; this rules out a broad “first on-chain rebalancer” claim. Jayo's current testnet rUSDG is not Paxos USDG. The mainnet fork proves technical compatibility with Paxos USDG, not a live production integration. The [official judging criteria](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon?tab=custom-dfc39bda-c613-4658-8df9-f35b527dace5) include product-market fit and real problem solving; polished UI and many tests cannot substitute for an owner benefit.
