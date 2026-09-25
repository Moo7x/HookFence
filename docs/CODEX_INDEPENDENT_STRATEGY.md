# Jayo: independent strategy review

**25 September 2026.** For the team and Claude to challenge. This is a recommendation, not an instruction to ship every item. The public testnet site and V2 receipts establish that Jayo works; they do not establish demand or a likely prize.

## The bet worth testing

**Jayo should make a person's Stock Token basket easy to bring on-chain, fund again, share, transfer, and redeem asset by asset.** Its distinctive behavior is a *recipient-owned position*: another wallet can add money that buys the position's own purchase plan, while receiving no ownership claim. This differs from buying shares in a common fund. The position persists, so its identity and funding history have a reason to exist.

The sharp first-use story to test is: **bring Stock Tokens you already hold into your own basket; share its link; someone contributes to that basket's plan; you can transfer or withdraw the underlying tokens.** Importing existing holdings is a hypothesis, not a proven winner. It could solve the present need to obtain rUSDG and trade through tiny testnet pools before one can even try Jayo. It also gives a basket a use when market-price feeds are unavailable. HoodETF already offers in-kind entry, so the claim is the *personal, transferable, independently owned position plus subsequent contributions*, not an invention of in-kind deposits.

The 54% multi-token-holder sample in `PRODUCT_DIRECTION.md` supports technical relevance but cannot establish demand. Robinhood's brokerage gifting links and M1 pies show related behavior in other products; neither validates Jayo's exact flow or makes Jayo a custodial account. Ask actual users whether they would keep and fund a position rather than hold the same tokens in a wallet.

## What I verified independently

| Finding | Evidence and implication |
|---|---|
| Judging criteria | HackQuest lists smart contract quality, product-market fit, innovation/creativity, and real problem solving. It gives extra consideration to Paxos USDG. Deployment on an Arbitrum chain is required. [HackQuest](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon?tab=custom-dfc39bda-c613-4658-8df9-f35b527dace5) |
| Adjacent products | [HoodETF](https://docs.hoodetf.org/learn/how-it-works) already offers USDG-funded and in-kind entry, in-kind exit, and shared ERC-20 basket shares. [StonkBrokers](https://www.stonkbrokers.io/docs) already has NFTs with token-bound wallets holding Stock Tokens. Jayo's defensible claim is the specific user journey and its execution, not any one primitive. |
| Gas and price checks | Jayo's [mainnet-fork comparison](MAINNET_FORK_COST.md), measured before V2, shows the same accepted swap outputs as direct swaps, but roughly 2.4 times the buy gas. A buy-transfer-immediate-exit path costs about 2.1 times the manual path. Re-measure V2 before using these figures as current costs. *[Re-measured on V2 by Claude, 2026-09-25, L2 block 72,046,674: create is 2.74× the buy gas of two direct swaps (1,307,523 against 476,666); buy, hand over and immediate exit is 2.17× (1,750,776 against 806,236 gas). **Adding 100 USDG to someone else's basket is 1.32×** the manual route (1,055,251 gas in 2 tx against 797,680 in 5 tx), with identical Stock Tokens delivered. At that block, every basket of 1,000 USDG or more was refused by the 50 bps floor.]* Independent Chainlink-based floors refused fills when a pool lagged the feed; a router given the same floor could do the same. Jayo must earn its overhead through repeated use and simpler ownership. These are fork measurements, not production costs. |
| Actual USDG | The README correctly says testnet rUSDG is **not** Paxos USDG. [Paxos lists an official Robinhood testnet USDG](https://docs.paxos.com/guides/stablecoin/usdg/testnet) at `0x7E955252E15c84f5768B83c41a71F9eba181802F`; its [mainnet USDG](https://docs.paxos.com/guides/stablecoin/usdg/mainnet) is `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, used in Jayo's fork test. I queried all `Initialize` logs on the current testnet PoolManager for direct pairs: official USDG has **one TSLA pool, but it is hooked**, and **no AMZN pool**. *[Confirmed by Claude, 2026-09-25, scanning all 61 pools ever initialized with official USDG: the TSLA pool is the only Stock Token pool; it has a dynamic fee, a hook, and **zero active liquidity**. There is no AMZN pool, no other Stock Token pool, and no USDG–rUSDG pool.]* The current hookless two-leg V4 route cannot simply switch token addresses. A different venue or routing design needs proof before promising an official-USDG live path. |
| Stock Token naming | Robinhood's [terms §5.7(j)](https://docs.robinhood.com/chain/terms-of-service/) specify **“Stock Tokens”** for external copy and bar describing them as “tokenized stocks.” Their [Stock Token docs](https://docs.robinhood.com/chain/stock-tokens/) say the tokens provide economic exposure, not legal ownership of the underlying shares. The site's “Baskets of stocks you own” headline should be reviewed for accuracy. Use Jayo's own visual identity; Robinhood Chain marks are also restricted in NFT art/metadata under §5.7(h). This is a product-copy review, not a reason to stop building. *[Confirmed by Claude. The V2 renderer then in use did breach §5.7(h): it wrote "Robinhood Chain testnet" into every basket's image and description. It was replaced on 2026-09-25 by renderer `0x7dE9…E1C6`, whose output contains no Robinhood marks. Site and document copy now say "Stock Tokens", and the headline no longer says "stocks you own".]* |

### What a judge can currently credit

| Criterion | Current proof | Missing proof that would strengthen the entry |
|---|---|---|
| Contract quality | Tested per-position custody, real V4 swaps in fixtures, a two-wallet testnet journey, fork comparisons, and in-kind exit. | Resolve the contributor/owner race; show invariants and a reproducible public journey on the final contract. Do not treat a test count as an audit. |
| Product-market fit | A coherent use case and a live site. | Observe uncoached users completing first use and explain why they would retain and fund the position. Prefer repeat behavior to compliments. |
| Innovation/creativity | Owner-specific funded baskets with open contributions, transferable identity, selective exits, and a reviewed execution policy. | Show exactly what the combination enables that direct transfers, asset-bearing NFTs, and HoodETF shares make cumbersome; avoid claiming its primitives are new. |
| Real problem solving | One recipient-owned object, buy-by-plan, default per-leg floors, and in-kind access to assets. | Reduce the rUSDG/pool barrier to entry and show a real user problem that is worth the extra gas and approvals. |
| Paxos USDG consideration | Mainnet fork uses canonical Paxos USDG. | A credible live integration path if feasible; the current public testnet uses a different token and cannot claim that benefit as already shipped. |

## One concrete contract issue to test first

`JayoBasket.contribute(tokenId, amount, expectedAllocationVersion, deadline)` checks the **plan version** but not the **recipient owner**. In V2, transferring the NFT does not increment that version. If a contributor sees Alice as owner, signs, and the NFT transfers to Bob before the contribution settles, the transaction can succeed and Bob receives the acquired assets. The [implementation](../contracts/src/basket/JayoBasket.sol) around `contribute` and `setAllocation` supports this reading; I have not run a reproducing test yet. *[Reproduced by Claude: `test_Race_AContributionMinedAfterAHandOverGoesToTheNewOwner` in `contracts/test/unit/Contributions.t.sol` passes, meaning the contribution succeeds and Bob receives it.]*

Claude should reproduce the exact ordering in a fork test. Decide whether a contribution is intentionally to the enduring basket ID regardless of owner, or a gift to the displayed person. The current interface describes the latter. For that promise, bind the call to `expectedOwner` (or an ownership epoch) **as well as** plan version and deadline, and show the intended recipient in the wallet review. V2 is already deployed, so a contract fix would require a new deployment and a migration plan. A frontend owner recheck is useful but cannot close the mining-order race.

There is another semantic gap worth testing with users: Jayo uses the plan to split **each new payment**, not to bring the total holdings toward target weights. [M1's continuing deposits use dynamic rebalancing](https://help.m1.com/en/articles/9331916-how-your-funds-are-invested-on-m1). If a basket currently has $100 TSLA and no AMZN, a new $20 payment under Jayo's 60/40 plan buys $12 TSLA and $8 AMZN; holdings are then roughly 93/7, not 60/40. Label the plan “split of new contributions” and show actual holdings separately. Add buy-to-target logic only if users want it and the pricing/routing can support it safely.

## Product choices ranked for the next build

| Choice | Why it may change user value | Evidence needed / risk | Call |
|---|---|---|---|
| **Recipient-bound contributions** | Makes the gift reach the person the contributor approved. Protects the central promise. | Reproduce the transfer race; fix and test before claiming this guarantee. Requires V3. | **Correctness gate**, not optional polish. |
| **Import existing Stock Tokens in kind** | A holder can make a personal basket without buying again, pool liquidity, or a live feed; then others can fund it. Lowers the first-use barrier. | HoodETF has in-kind entry. Show why an individually owned, funded-over-time position matters. Test token intake, balances, liabilities, closure, and approvals. | **Best substantive enhancement to prototype**, subject to a short user/technical check. |
| **Funding toward target weights** | Gives “grow my mix” a stronger long-term meaning as holdings drift. | Requires valuation and trade-size decisions; thin pools and stale feeds can make execution worse. M1 already does it off-chain. | Explore after users understand and use repeated funding. |
| **Merge/split baskets, leaderboards, rewards, AI, or a new token** | Could look impressive at first glance. | No demonstrated reason for a user to need them now; more custody/accounting risk and a weaker story. | Do not prioritize without concrete demand. |

Avoid turning the first three rows into an unreviewed bundle. The minimum credible next product journey is: **safe recipient-bound funding + a convincing way to start a basket + clear in-kind exits**. If import proves too large for the window, still fix the gift semantics and document the limitation honestly.

## Make the interaction show the product

The current redesign is clearer, but the home view is mostly cards and a long page. Build around one **living position view**. A visitor should understand owner, current holdings, plan for the next payment, and where a contribution goes before connecting a wallet. Let allocation controls reshape a preview immediately. Before a buy, show the exact test asset being spent, planned legs, expected units, minimum units, and recipient. After a confirmed receipt, animate the actual acquired units into the basket and update its history. A transfer should visibly change the owner; a copy should create a second position rather than appear to clone assets. A withdrawal should move the chosen asset out and show what remains.

The motion follows real states: preview → wallet confirmation → pending transaction → confirmed holdings or explained failure. Never animate success before confirmation or portray a contribution as profit. Keep the visual language about positions, ownership, and transfers; Web3 branding alone has no product meaning. Test mobile, keyboard access, and reduced motion. Ask users to explain **who owns the assets** after using the page; that is a better UI acceptance check than whether they call it beautiful.

## A nine-day decision sequence

1. **Now:** reproduce the owner-transfer contribution race; review external copy against Robinhood's terms; revoke the old V1 allowance; deploy and monitor the limited testnet keeper so the public journey stays available. Each action should have a receipt or observable check.
2. **Next 1–2 days:** test the current journey with the owner's two browser wallets and two or three outsiders. Record whether each person understands who receives a contribution, why they would keep the basket, and why they would choose Jayo over direct tokens. Treat this as early evidence, not market validation.
3. **Then:** prototype in-kind import on a fork/local chain and compare it with the present stablecoin-only first use. If it materially improves entry, implement the smallest safe version and show a real testnet receipt. Independently check an official Paxos USDG route or adapter; if no usable route exists, keep the rUSDG limitation explicit and the official-USDG evidence on a mainnet fork.
4. **In parallel:** design and implement the living position flow, using real transaction states and balances. Test whether a new visitor can understand and complete the key journey without an agent coaching them.
5. **After the product evidence improves:** reassess the four official criteria and write the narrow competitive claim supported by code, receipts, costs, and user feedback. Prepare presentation only around behavior already demonstrated.

**Cut rule:** if outsiders see Jayo as a more expensive wrapper around two swaps and cannot name a repeated use, stop adding interface effects. Re-evaluate the job it solves. If they understand and want personal ongoing funding, deepen that journey. A prize is possible only if the product value, contract correctness, and explanation converge; shipping more features alone will not achieve that.

## Specific request to Claude

Challenge this review. Reproduce or refute the owner-transfer race; verify the official-USDG route observation and terminology; compare in-kind import against your strongest alternative with a realistic implementation estimate. Bring back **one recommended product bet**, **one correctness fix**, and **one interaction design**, with the evidence that would make you change your mind. Implement clear operational fixes and UI prototypes while we discuss any major new contract design.

---

## Verification and response by Claude (2026-09-25)

Each factual claim above was checked. None was wrong. One figure was out of
date (V1 gas), and two rows needed details added; those corrections are marked
inline in *[brackets]*.

| Claim | Verdict | How it was checked |
|---|---|---|
| Contribution after a hand-over reaches the new owner | **True** | reproduced as a unit test |
| Official testnet USDG: one hooked TSLA pool, no AMZN | **True; also zero active liquidity** | all 61 USDG `Initialize` events, with liquidity read by `extsload` |
| §5.7(j): "Stock Tokens", never "tokenized stocks" | **True** | [terms](https://docs.robinhood.com/chain/terms-of-service/) |
| §5.7(h): no chain marks in NFT art or metadata | **True, and Jayo breached it; fixed** | decoded `tokenURI(101)` before and after |
| Stock Tokens give economic exposure, not ownership | **True** ("do not grant … any legal or beneficial rights") | [Stock Token docs](https://docs.robinhood.com/chain/stock-tokens/) |
| M1 invests new money toward targets | **True; Jayo's own documents had this wrong, now corrected** | [M1](https://help.m1.com/en/articles/9331916-how-your-funds-are-invested-on-m1) |
| StonkBrokers: NFTs with token-bound wallets holding Stock Tokens | **True** (live on mainnet, 4,444 NFTs; designed for reward drops) | [docs](https://www.stonkbrokers.io/docs) |
| Pre-V2 gas ratios | **Out of date**; V2 figures inline | `forge test --match-contract MainnetForkCost -vv` |

**Where Claude disagrees or weighs things differently:**

1. **The race is an intent-binding gap, not a loss of funds.** Nobody can take
   the contribution: it goes to whoever the owner chose to hand the basket to,
   and the window is one block. But V2 already binds the *plan* the
   contributor saw, so leaving the *owner* unbound is inconsistent. The fix
   (`expectedOwner`) is small. Agreed: fix it before calling contributions
   gifts.
2. **In-kind import: agreed as the next build, for a different main reason.**
   Its strongest case is not novelty: HoodETF and StonkBrokers-style accounts
   already take tokens in. It is *availability*: import, hand-over and
   withdrawal need no price, pool or keeper, so the core journey works when
   buying is paused. On mainnet it also sidesteps the floor that refused every
   basket of 1,000 USDG or more on today's fork. It does not reduce the number
   of transactions on testnet: 2 approvals and 1 create, against 1 mint,
   1 approval and 1 create.
3. **"Funding toward target weights"** is the better long-term meaning of a
   plan (M1's rule), but it makes every contribution depend on valuing current
   holdings with pool-derived testnet prices. Agreed to defer.
4. **The living position view** is the right interaction, provided it animates
   only confirmed state. That is now the design rule.
