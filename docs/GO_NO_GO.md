# Jayo: go / no-go (2026-09-25)

**Recommendation: NO-GO on Jayo as the main hackathon product.** Keep the
contracts, site and evidence as a technical prototype. Build nothing further
on Jayo until a different product problem passes a user-benefit test.

This review was bounded to evidence already measured, plus three checks made
for it:
- a re-scan of the gallery (64 projects);
- Rico OTFs' project page;
- a census of mainnet Stock Token pools (`node scripts/find-routes.mjs mainnet TSLA AMZN NVDA AAPL`).

## The root problem

Jayo's core design is a **custodial NFT wrapper for one person's basket of
Stock Tokens**. For the person paying, holding the same Stock Tokens in their
own wallet is strictly better:
- it is cheaper;
- the tokens stay usable in other protocols, such as lending against them;
- there is no extra contract risk.

Every use case tried so far was an attempt to find a reason for the wrapper.
"Contributions" and "gifts" were one such attempt, and the weakest: the person
paying gets nothing, and a recipient can simply receive stablecoins. That
direction was proposed and built in this repository on 2026-09-25, with "demand
untested" written beside it. It should not have become the headline.

## Measured comparison, same pools, same block

Mainnet fork at L2 block 72,046,674; ETH $2,677, base fee 0.0385 gwei, L2
execution only. Sources: `docs/MAINNET_FORK_COST.md`,
`test/fork/MainnetForkCost.t.sol`.

| Task (60/40 TSLA/AMZN) | Jayo v3 | Own wallet + DEX | HoodETF | Rico OTFs |
|---|---|---|---|---|
| Buy $20 | 1,307,523 gas (≈ $0.135); tokens held inside an NFT | 476,666 gas (≈ $0.049); **identical amounts**, in your wallet | shares of a creator's fund; up to 3% entry, 3%/yr, 1% exit | fund units, keeper-managed |
| Buy $1,000 | **refused** by the 50 bps floor (a swap pays 0.41–0.50% over Chainlink) | fills at that price | fills (price impact on zap) | fills from buffer or keeper |
| Add $100 later by the same split | 954,652 gas | 2 swaps; a wallet UI could compute the split | buy more shares | deposit |
| Hand the whole position to someone | 69,489 gas (1 NFT) | 163,617 gas (2 transfers) | 1 transfer | 1 transfer |
| Use the tokens elsewhere (collateral, trading) | not until withdrawn | directly | shares are ERC-20 | units usable as collateral (per Rico) |

Jayo wins one row, handing over a multi-token position, and that saves about
$0.01. Everywhere else it costs more, locks the tokens, or does less.

## The alternatives in Codex's reset, challenged

| Candidate | Who pays | What they would gain | Why it fails |
|---|---|---|---|
| **Maintaining my own target mix** (Codex's first choice) | the owner, each month | not having to work out which Stock Token is underweight | The computation needs no custody. A wallet screen can read balances and send the right swaps from the user's own wallet, with tokens staying there. The fund version already exists: Rico rebalances fixed-weight and market-cap funds with a keeper and an oracle NAV; HoodETF offers fixed baskets; M1 does it off-chain. Jayo's wrapper adds cost for nothing here. |
| **Trading a whole portfolio as one position** | a buyer and a seller | one atomic trade instead of several swaps | It needs a counterparty, a price for the bundle, and a marketplace; none exists for these NFTs. A buyer can assemble the same bundle from pools in minutes. The seller can withdraw just before a sale unless an escrow is built. It cannot be shown to work with real demand in nine days. |
| **Better basket execution** | a trader | better fills | Accepted Jayo fills are **identical** to direct swaps (asserted). Liquidity is concentrated: one pool per Stock Token dominates (TSLA $15.9M, NVDA $9.6M, AAPL $11.2M plus $3.0M, AMZN $558k), so splitting gains little except on large AMZN or AAPL orders. Aggregators already run here (the Stonk Exchange's Relay desk, Robinhood Wallet's in-app swaps). The oracle floor is a *feature*, and the gallery has several projects built around it (Custos, RWA Guard, Parity, batpilot's guard, RWA.Index). |
| **Gifts and contributions** (the v2/v3 headline) | a giver | nothing | Rejected: no benefit to the payer; the recipient prefers stablecoins; the precedent used (Robinhood custodial accounts) is a US product for minors, and Stock Tokens cannot be offered to US persons at all. |

## What is worth keeping

This is evidence of engineering quality, not a product:
- per-position custody with an invariant campaign (five properties, 25,600
  random calls);
- additions bound to what the user saw;
- exits that need no price;
- a policy that refuses fills against Chainlink, handles `oraclePaused` and
  corporate-action windows, and checks the sequencer;
- a bounded, keyless-owner price keeper;
- a public site with tight security headers;
- honest measurement on a mainnet fork.

Any next product can reuse the gateway, policy, adapter, fork tooling and site
shell.

## Decision rule for anything next

Before any build:
- name one person;
- name the task they already do today;
- give the measured cost or loss they suffer doing it;
- show the alternative they would use instead, and why it is worse.

If that cannot be shown with on-chain data or a real user within one day, do
not build it.
