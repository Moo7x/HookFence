# What the closest alternatives do, and the two things worth adding

**Updated:** 2026-09-24, after HoodETF was pointed out. Written as reference, not
as a reason to pivot. Jayo's promise is frozen and nothing here proposes
changing it:

> Build a funded token basket, own and transfer it as one position, copy its
> allocation using your own funds, and withdraw its underlying assets.

---

## 1. HoodETF is the closest alternative, and it already does two things this document used to call Jayo's

HoodETF builds token baskets on the same stack Jayo targets — USDG, Uniswap v4,
Robinhood-style equity tokens, Chainlink. Its documentation, read 2026-09-24:

- [How to buy](https://docs.hoodetf.org/guides/buy) — pay in USDG ("zap") or
  deposit the constituents in kind; receive ERC-20 shares; slippage enforced by
  an on-chain `minSharesOut` floor.
- [How it works](https://docs.hoodetf.org/learn/how-it-works) — in-kind
  redemption: "burn shares, receive your proportional slice of every
  constituent", described as permissionless and never pausable. Chainlink is used
  for display, one-click pricing and fee accounting, and "never to decide whether
  you can deposit or withdraw". Baskets are immutable after creation.
- [Fees](https://docs.hoodetf.org/learn/fees) — entry up to 3%, management up to
  3%/yr streamed by dilution, exit up to 1% (on in-kind redemption too), each set
  by the basket's creator and split 90% creator / 10% protocol; zaps also pay
  Uniswap price impact.

**So neither of these is Jayo's, and this document no longer claims them:**

- **USDG in, basket out.** HoodETF does it.
- **Oracle-free, in-kind withdrawal that works when prices are unavailable.**
  HoodETF does it too. An earlier version of this page called Jayo's unpriced
  withdrawal "the real, defensible difference". Against dHEDGE it was; against
  HoodETF it is not. Jayo's withdrawal still works on a weekend and that is
  still worth demonstrating — it is simply not a differentiator.

### What is actually different

The difference is structural, and everything else follows from it: **a HoodETF
basket is one shared vault that many people own shares of; a Jayo basket is one
position that one person owns, holding exactly what that person's own purchase
bought.**

| | HoodETF | Jayo |
|---|---|---|
| What you hold | ERC-20 shares of a shared vault | one ERC-721 position with its own recorded holdings |
| Whose tokens are "yours" | your fraction of everything in the vault | exactly the amounts your purchase bought, per asset, in the contract's ledger |
| Recipe | set by a creator, immutable, shared by every holder | set by you, per position |
| "Copying" a basket | buy shares of the creator's vault; the creator earns fees on your money for as long as you hold | `copyAllocation`: take the recipe once, buy with your own money into a separate position; the source owner receives nothing and gives up nothing |
| Partial exit | a proportional slice of **every** constituent; or zap out to USDG | a proportional slice (`redeemFraction`) **or one named asset in full** (`redeemAsset`), in kind |
| Single-asset exit, in kind | not offered — and a shared vault cannot offer it without shifting every other holder's ratio | yes, because the position's holdings belong to nobody else |
| Moving the whole position | send the shares (fungible) | send the NFT; the specific holdings move with it |
| Exit to stablecoin | one transaction (zap out) | **not offered** — you receive the tokens and sell them yourself |
| Deposit in kind | yes | **no** — USDG only |
| Composability | fungible shares can trade on a DEX or sit in other protocols | an NFT per position; no secondary-market price |
| Creator incentive | yes, 90% of fees | **none** |

### What each actually costs the user

| | HoodETF | Jayo |
|---|---|---|
| Entry fee | up to 3%, creator-set | **0** |
| Management fee | up to 3% a year, by dilution | **0** |
| Exit fee | up to 1%, including in-kind | **0** |
| Protocol cut | 10% of the above | **0** — the contracts contain no fee path |
| Pool costs on the way in | swap price impact on zaps | the pool's LP fee plus price impact on each leg, capped by the policy floor (refused past it) |
| Pool costs on the way out | swap impact on zap-out | none in kind; if you want USDG you pay to sell yourself |
| Rounding remainder | — | returned to you in the same transaction |

Measured Jayo figures, not estimates:

- **Pool cost** on Robinhood Chain testnet, one TSLA leg, same block
  (`TestnetJourney.t.sol`): 1 rUSDG → 34 bps, 10 rUSDG → 78 bps, 50 rUSDG →
  269 bps, of which 30 bps is the pool's own fee. Testnet pools are tiny; these
  numbers say nothing about mainnet depth, which is still unmeasured.
- **Gas**, from receipts on a fork of that testnet (`scripts/estimate-testnet-cost.mjs`):
  a two-leg `create` is 917,294 L2 gas plus 16,441 L1 data gas;
  `copyAllocation` 821,487 + 11,817; `redeemAsset` 105,265 + 10,261. At the
  chain's current 0.01 gwei that is under 0.00001 ETH per action. HoodETF's gas
  is not published and has not been measured, so no gas comparison is claimed.

The honest reading: for someone who holds a basket for a year, Jayo's zero fees
matter — a HoodETF basket at its maximum settings costs up to ~7% in fees over
that year, before swap costs, and one at lower settings costs less; the actual
rate depends on the creator. For someone who wants to trade in and out in USDG,
or wants the position to be composable, HoodETF is the better tool today.

### Where this leaves Jayo's pitch

Not "the only basket with oracle-free withdrawal". Instead:

> Your own basket, not a share of someone else's. Build it to your own recipe,
> hand the whole thing over as one object, copy anyone's recipe without paying
> them, and take out exactly the asset you want — with no fee to anyone.

Every clause of that is true of Jayo and false of a shared-vault design, and
each is demonstrable in the interface.

---

## 1a. The earlier comparison (dHEDGE, index tokens, copy-trading bots)

Kept for reference. dHEDGE's in-kind withdrawal values the position at NAV
before paying it out, so it does depend on prices; fungible index tokens
(Set, Index Coop) need a NAV at issuance; copy-trading bots mirror trades
continuously through a keeper. None of those changes the conclusion above,
because HoodETF is closer to Jayo than any of them.

---

## 2. Recommendation 1 — partial, in-kind withdrawal  (BUILT 2026-09-23)

**The gap.** `redeem()` is all or nothing: it delivers every asset and burns the
position. Wanting your AMZN back while keeping the rest means destroying the
basket, losing its identity, its allocation record and any manager you granted,
then rebuilding it — which costs two more round trips through the pool.

**What to build.** Two functions, both reading no price:

- `redeemAsset(tokenId, asset)` — deliver one leg's recorded amount, keep the
  position.
- `redeemFraction(tokenId, bps)` — deliver that fraction of **every** holding.

**Concrete benefit.** You can take money out of a basket without giving up the
basket. Because neither path values anything, both keep the property the whole
design is built around: they work on a weekend, during a corporate action, and
with every feed stale.

**How to demonstrate it, in one screen.** Use the existing "Skip forward 48
hours" control so every feed is past its heartbeat, then in the same block:

1. "Create basket" → refused, in plain words: *prices are unavailable.*
2. "Withdraw just my AMZN" → succeeds; the basket survives holding only TSLA.
3. The contract's own numbers, shown on screen: `totalLiabilities[AMZN]` drops
   to zero, `balanceOf(basket)` drops by exactly the same amount, and the
   solvency invariant `totalLiabilities[asset] <= balanceOf(this)` still holds
   for both assets.

Two opposite outcomes from one price condition, side by side. The unpriced
withdrawal is not unique (HoodETF's is also oracle-free); taking out **one named
asset in kind** is the part a shared vault cannot do.

**Cost and the risk to watch.** Small — one new entry point, the same
effects-before-interactions ordering `redeem()` already uses. The thing to get
right is bookkeeping, not arithmetic: `_assetsOf[tokenId]` must drop a leg that
reaches zero, the allocation record must keep meaning something afterwards so
`copyAllocation` does not report a recipe the position no longer follows, and a
partial exit must never leave `totalLiabilities` above the real balance.

---

## 3. Recommendation 2 — creation that waits for the market, instead of refusing

**The gap, measured.** `PHASE0_EVIDENCE.md` §9 records that every Robinhood
Stock Token feed runs 36–45 hours old against a published 24-hour heartbeat,
because equities trade 24/5 and crypto does not. Jayo's correct behaviour is to
refuse. Refusing for a third of the week is correct and it is also not a
product — and it is the one place where every alternative beats us.

**What to build.** Let a user commit funds and an allocation now, and have the
basket built when the reference is valid again:

- `requestCreate(allocation, usdgIn, notAfter)` — escrows the USDG against a
  pending request the user can cancel at any time until it settles.
- `settle(requestId)` — permissionless. Runs the ordinary `create` path, with
  the ordinary per-leg floors, at a moment when the feeds are fresh. Anyone can
  call it; there is no privileged keeper.
- Expiry returns the funds. The user's floor is their own signed one, so a
  settler cannot fill them worse than they agreed to.

**Concrete benefit.** "The market is closed, come back Monday" becomes "we will
build it when the market opens, and you can cancel until then." The user acts
when they decide to, not when the oracle allows.

**How to demonstrate it.** With the demo clock past the heartbeat: submit a
request → it is accepted and the escrowed amount is shown; press "Refresh
prices" (the market reopening) → press Settle from a *different* wallet, to show
it needs no privileged party → the basket appears, owned by the requester, at a
price inside the floor they signed. Then repeat and press Cancel instead, and
show the funds return in full.

**Cost, honestly.** This is the larger of the two and the only item here that
adds a genuinely new risk surface: the contract holds user funds between two
transactions. That means escrow accounting, cancellation, expiry, and a settle
path that cannot be used to fill someone at a worse price than they agreed.
`docs/EXTENSION_ASSESSMENT.md` estimated ~70% of the existing engine carries
over unchanged, which matches — the policy, the adapter and the evidence struct
are called at settle time exactly as they are called now.

**If the timeline is tight, the cheaper substitute** is `addFunds(tokenId,
usdgIn)` — buy more at the position's recorded allocation instead of creating a
new basket every time. It is most of a day's work rather than several, it holds
no funds between transactions, and it covers the common case of building a
position gradually. It does not fix the weekend, which is why it is the
substitute and not the recommendation.

---

## 4. Deliberately not recommended

- **Rebalancing.** Every alternative has it. It is still the wrong thing for
  Jayo: it turns a custody product into a trading product, invites fee
  extraction on every drift, and is where basket accounting bugs live. Staying
  out is a decision, recorded in `docs/JAYO_BUILD_LOG.md`, not an oversight.
- **Fungible basket shares.** Would let several people co-own one basket and
  trade it. It also forces a NAV at every deposit and withdrawal, which
  reintroduces exactly the oracle dependency that `redeem()` exists to avoid.
  The trade is not worth it.
- **Manager performance fees.** Pays people to churn. Nothing in the frozen
  promise needs it.
