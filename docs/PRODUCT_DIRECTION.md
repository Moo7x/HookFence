# Where Jayo goes next, and why

**Date:** 2026-09-25. The product decision after the first real-wallet run on
<https://jayo-testnet.pages.dev>. The suggestions from the owner and from the
Codex review were treated as hypotheses and checked against the chain, the code
and the competition before any of them was built.

## 1. What was checked, and what it showed

### The five leads from the review, verified

| Lead | Verdict | Evidence |
|---|---|---|
| `tokenURI(5)` is empty | **true** | `cast call … tokenURI(5)` returns `""`; V1 has no metadata at all, so wallets show a blank NFT |
| A position cannot be funded again | **true** | V1 has `create` and `copyAllocation` only; both mint a new token |
| The recipe stays after selective withdrawals | **true, by design** | `redeemAsset` leaves `_allocationOf` alone; it is what `copyAllocation` copies |
| Sequential single-asset withdrawals leave an empty NFT | **true, reproduced on the public testnet** | Bob took AMZN then TSLA out of #6 through the page (`0x020de6c9…01d9`, `0xd30f7027…dfb9`); `ownerOf(6)` is still Bob, `holdingsOf(6)` is empty, the recipe is still 60/40, and the page still offers to hand it on |
| No linkable page explains a position to its recipient | **true** | the recipient has to find the basket in a list of everyone's baskets |

### The journey through the page (hosted build, two ordinary wallets)

Run on 2026-09-25 against the byte-identical hosted build (`site/dist`), with the
test wallet standing in for a browser extension:

| Step | Receipt | Result |
|---|---|---|
| Alice approves exactly 20 rUSDG | `0x4c3e7c57…dbd0` | the new exact-amount approval, not an open one |
| Alice creates #6 (60/40, 20 rUSDG) | `0x53afe53f…0ba9` | 0.041996 TSLA + 0.033758 AMZN |
| Alice hands #6 to Bob | `0x97bfa81a…13f4` | address typed, reviewed, acknowledged |
| Alice tries to withdraw from #6 | simulated | contract refuses: `NotPositionOwner(6, Alice)`; the page had already disabled the button, **but never said why** |
| Alice copies #6 with her own 10 rUSDG | `0x7717705b…380f`, `0xde0fdfd3…d98a` | new basket #7, #6 untouched |
| Bob takes only AMZN out of #6 | `0x020de6c9…01d9` | 0.033758 AMZN to Bob, #6 kept |

Confusing or wrong in the interface:
- My baskets and other people's are one mixed list. With no wallet connected,
  every basket is labelled "someone else's".
- A non-owner sees the withdraw and hand-over controls disabled, with no
  explanation. After a hand-over, the hand-over form is still shown.
- An empty basket can still be offered for hand-over.
- The recipient gets no link, and their wallet shows a blank NFT.
- Setup, the price-feed panel and the risk notes sit above the product itself.

### Chain conditions

- **Who already holds these tokens.** Testnet TSLA has 225,292 holders and AMZN
  has 288,878, from the faucet. rUSDG, the stablecoin Jayo buys with, has **8**.
- **Mainnet is active.** In the last 5.6 hours (200,000 blocks), TSLA changed
  hands between 2,016 distinct addresses, AMZN 1,465 and NVDA 9,826. Of 204
  sampled wallets that currently hold any of TSLA, AMZN, NVDA or AAPL, **54% hold
  two or more of them.** Holding a mix of stocks is the normal case, not a niche.
- **Testnet prices against the independent feed.** No independent feed exists on
  testnet: Chainlink's feed directory lists Robinhood Chain mainnet only, and on
  testnet the stock tokens' `oraclePaused()` reverts. Mainnet Chainlink today:
  TSLA $378.34, AMZN $250.11. Testnet pools: TSLA $283.30 (**25% below**), AMZN
  $234.45 (6% below). A feed that copied real prices onto testnet would set
  floors far below what the pools actually return, so it would protect nothing.
  If a pool ever traded above the real price by more than 3%, it would refuse
  every purchase. **Decision: keep the testnet reference pool-derived, and label
  it as such. Independence is shown only on the mainnet fork.**
- **Pool depth.** About 2,129 rUSDG of active liquidity for TSLA and 1,027 for
  AMZN. Around 20 rUSDG per purchase is the practical size.

### Competitors and the gallery (64 projects, read 2026-09-25)

- **HoodETF**: shared baskets, one vault per recipe, with ERC-20 shares; USDG or
  in-kind entry, in-kind exit; the creator sets fees. You own a share of
  *someone's* fund.
- **batpilot** (gallery): scheduled recurring buys and stop-loss or take-profit
  for **single** stock tokens, run by a Cloudflare Workers keeper; "baskets" is on
  its roadmap. So "keep adding to your holding" is not Jayo's alone.
- **NERON & LYRA** (gallery): copy-trading bots. **INSTANT WIN**: prize
  distribution. Nobody in the gallery does individually owned, transferable
  multi-asset positions.
- **Existing asset-bearing NFTs** (ERC-6551 token-bound accounts, Uniswap v3 LP
  NFTs): an NFT holding assets and showing its contents on-chain is standard. Jayo
  claims neither as new.

### Off-chain behaviour that matches the direction

- **M1 Finance "pies".** A user-defined mix with target weights. "Every deposit
  … will be allocated to your holdings according to these percentages"; a pie
  can be shared as a link and copied
  ([M1 help](https://help.m1.com/en/articles/9331991-share-a-custom-pie-on-m1)).
- **Robinhood custodial accounts** (launched 2026-03-05). They "support recurring
  investments and allow family and friends to contribute through a new gifting
  experience"
  ([report](https://finviz.com/news/330759/robinhood-stock-rises-after-platinum-card-custodial-accounts-launch)).

Adding money to someone's own portfolio, split by *their* plan, is a behaviour
people already use in brokerages. On-chain there is no equivalent for an
individually owned multi-asset position.

## 2. The person and the task

**The person:** someone on Robinhood Chain building a small portfolio of stock
tokens for themselves or for someone else, who wants it to keep growing and to
be handed on as one thing.

**The task:** "put money into *this* portfolio, split the way it's meant to be
split." This covers the owner's own monthly top-up, a relative adding to a
child's basket, or a friend chipping in to a shared gift.

| Doing that today | What goes wrong |
|---|---|
| Manual swaps and transfers | The contributor has to know the mix, make one swap per stock plus one transfer each, and nothing records that it was for this portfolio |
| HoodETF shares | You add to a creator's shared fund, with its recipe and fees, not to the recipient's own mix; the "gift" is shares of someone else's basket |
| Sending USDG to the owner | Nothing is bought, and the owner still has to do the swaps |
| An asset-bearing NFT (ERC-6551) | It can receive tokens, but nothing buys by a plan, protects the price, or shows who contributed what |

**What Jayo does differently, exactly:** one transaction by anyone turns
stablecoin into every asset of **that position's own plan**. Each leg is checked
against the reference floor, the result is credited to that position alone, and
the position's public page and on-chain metadata show its holdings, its plan and
who funded it. The owner can still withdraw any single asset, hand the whole
thing on, or change the plan for future money.

This is also the stronger reason to keep a position and pass it on. The
two-asset buy, hand-over and immediate exit costs about 2.1× doing it by hand
(`docs/MAINNET_FORK_COST.md`), so a position only earns its gas if it
*persists*: it keeps being funded, it has a page, and it can be handed on with
its history.

## 3. Directions compared

| Direction | User value | Difference from others | Contract risk | Cost to ship | What a real wallet test proves |
|---|---|---|---|---|---|
| **Contributions + position page** (chosen) | the position grows; it can be gifted into; the recipient sees what it is | the only on-chain way to add to someone's own mix in one step | medium: new entry point reusing the existing leg settlement | V2 basket plus renderer; V1 stays withdrawable | a second wallet adds to your basket; the same token id holds more; the page shows who and when |
| Position page alone | the recipient understands the gift | none: on-chain metadata is standard | low | small | the wallet displays the basket |
| Import holdings in kind | uses what 54% of holders already hold; no swap, no oracle | HoodETF and ERC-6551 already accept tokens in kind | medium: token intake and a recipe without prices | medium | a basket made from faucet tokens with no swap |
| Liquidity-aware planner | fewer refused purchases | an ordinary quote | none | small | a refusal predicted before signing |

The planner is worth adding as part of the interface (show the likely fill before
signing), not as the direction. Importing in kind is the natural next step once
contributions exist, and is recorded as future work, not built now.

## 4. What V2 changes, and why each one

1. **`contribute(id, amount, expectedPlanVersion, deadline)`.** Anyone can
   add stablecoin to an existing position, bought by its plan with the same
   floors as `create`. The expected version stops a plan change from redirecting
   a contribution already in flight.
2. **`setAllocation(id, plan)`.** Owner only. The plan is the split for
   *future* money. A new owner can make it theirs. Existing holdings are never
   rebalanced (V1's reasoning against rebalancing stands).
3. **Withdrawing the last holding closes the position.** No empty NFT can exist
   or be handed on.
4. **On-chain metadata.** `tokenURI` returns the holdings, the plan, the funding
   count and total, and a link to the position's page, with an SVG image. The
   renderer can be replaced by the owner. That admin power reaches metadata only,
   never funds.
5. **Dead code removed.** V1's `setManager` granted nothing and is gone.
6. **Ids start at 101**, so each basket number names one position across both
   contracts.

**V1 positions (#1–#7) are not stranded.** V1 is immutable and stays deployed.
The site lists V1 positions under "Earlier baskets", where owners can still
withdraw them in whole, in part or one asset at a time, and hand them on. They
cannot receive contributions, and the page says so.

## 5. Keeping the site usable while the owner's computer is off

Contributions and purchases need fresh feeds. The keeper moves off the laptop to
a scheduled Cloudflare Worker, and it signs with a **dedicated updater key**
that can do one thing: publish testnet reference prices within on-chain bounds.
Those bounds are a minimum interval between updates, a per-update step and a
24-hour band. The owner key goes back offline. Withdrawals, hand-overs and plan
changes never need a price. See `docs/UPDATER_ASSESSMENT.md` for the options
rejected and why.

The testnet reference remains **pool-derived** and is labelled that way on the
site. The mainnet-fork test is where independent feeds are demonstrated.
