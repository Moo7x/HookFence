# What the closest alternatives do, and the two things worth adding

**Date:** 2026-09-23. Written as reference, not as a reason to pivot. Jayo's
promise is frozen and nothing here proposes changing it:

> Build a funded token basket, own and transfer it as one position, copy its
> allocation using your own funds, and withdraw its underlying assets.

---

## 1. The closest alternatives, and where Jayo actually differs

| | Managed vaults (dHEDGE, Enzyme) | Fungible index tokens (Set, Index Coop) | Copy-trading bots | **Jayo** |
|---|---|---|---|---|
| What you hold | fungible vault shares in a shared pool | a fungible index ERC-20 | your own wallet, mirrored | **one NFT position with its own assets** |
| Deposit priced by | NAV, from oracles | NAV / issuance module | n/a | **no NAV is ever computed** |
| Withdrawal priced by | NAV, from oracles | NAV | n/a | **nothing — recorded holdings are transferred** |
| Withdraw in kind | yes, pro-rata, **but priced** | yes, via issuance | n/a | **yes, and unpriced** |
| Partial withdrawal | yes (incl. single-asset, by liquidating pro-rata) | yes | n/a | **no — all or nothing** |
| Add to an existing position | yes | yes | n/a | **no — every funding is a new basket** |
| "Copy" means | deposit into *their* vault; they keep control | buy their token | mirror their trades continuously via a keeper | **take the recipe, spend your own money, own the result** |
| Works while equity prices are unpublished | no | no | no | **withdrawal yes, creation no** |

Two of those rows are the real, defensible difference and both are already built
and tested:

**Withdrawal computes nothing.** dHEDGE's in-kind withdrawal still values the
position at NAV to work out your share, so it inherits the oracle. Jayo records
`holdings[tokenId][asset]` at purchase and `redeem()` transfers exactly that —
it reads no price, calls no oracle and consults no policy. Proven by running it
against a `RevertingPolicy` whose every function reverts, and again on the live
testnet fork with every feed driven past its heartbeat.

**Copying takes the recipe, not the custody.** Depositing into someone's vault
means they hold your money and can trade it. Mirroring a wallet means a keeper
watches them and fires transactions on your behalf, forever. Jayo copies the
allocation once, spends your money, and hands you a position they cannot touch.
The source owner receives nothing and gives up nothing.

**Where Jayo is plainly behind:** it cannot take part of a position out, it
cannot add to one, and it cannot act at all while equity prices are unpublished —
which on mainnet is roughly 2.5 days a week, because the Robinhood equity feeds
are 24/5. Every alternative built on spot DEX pricing keeps working through a
weekend. That gap is the subject of the two recommendations below.

---

## 2. Recommendation 1 — partial, in-kind withdrawal

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

Two opposite outcomes from one price condition, side by side. That is the
argument for the whole design, made in ten seconds.

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
