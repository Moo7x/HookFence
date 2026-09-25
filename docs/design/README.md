# Jayo's interface: before and after

Screenshots in `before/` were taken of the live site on 2026-09-25, before the
redesign. The screenshots in `after/` are the rebuilt site (`site/dist`, byte
for byte what Cloudflare serves), read against Robinhood Chain testnet. Both
sets were taken with `node scripts/screenshot.mjs`. The red "LOCAL VERIFICATION
ONLY" bar in some `after/` shots comes from the local test wallet that stands
in for a browser extension; it is not part of the site.

| | Before | After |
|---|---|---|
| Home, no wallet | `before/desktop-disconnected.png` | `after/desktop-home-disconnected.png` |
| Home, wallet connected | `before/desktop-connected.png` | `after/desktop-home-connected.png` |
| One basket, as its owner | (a panel lower down the same page) | `after/desktop-basket-owner.png` |
| One basket, as a visitor | (no such view) | `after/desktop-basket-visitor.png` |
| An error | (generic "did not go through") | `after/desktop-error-insufficient.png` |
| Phone | `before/mobile-disconnected.png` | `after/mobile-home.png`, `after/mobile-basket.png` |
| In a wallet (NFT image) | blank: `tokenURI` was empty | `after/wallet-basket-101.png` |

## What the old page got wrong

- **It looked like a security console**: near-black background, blueprint grid,
  monospace status strip, a stack of identical bordered cards.
- **The product sat below the setup.** First came "Get set up", then the
  price-feed panel, then a form, and the baskets themselves were fourth.
- **One list for everything.** Your baskets and everyone else's were mixed.
  With no wallet connected, every basket said "someone else's".
- **No page per basket.** A recipient could not be sent a link to what they had
  received, and their wallet showed a blank NFT.
- **Controls you couldn't use, with no explanation.** A non-owner saw the
  withdraw and hand-over controls, disabled, with no reason given. After a
  hand-over, the hand-over form stayed on screen.

## Decisions

**A consumer-finance identity, chosen for this subject.** The canvas is a cool
mist (#EEF2F3), cards are white, text is a deep petrol ink (#0F2229), and petrol
(#0B5563) is used for every primary action. Coral (#EE6A4C) has one meaning
only: money being *added* to a basket. The gift button, the "Added to 1×" tag
and the history dot for an addition all share it, so the product's new
behaviour is recognisable anywhere. This avoids both the dark-console look and
the common cream-and-terracotta default. The on-chain renderer was first drawn
in exactly that default; it was redeployed in the site's palette.

**Type.** Bricolage Grotesque is used only for headlines and basket numbers:
it is characterful, and a basket number like "#101" reads as the name of an
object. Everything else is set in Figtree with tabular figures, so amounts line
up. Monospace appears only for wallet addresses, because Figtree's zero reads
as the letter O ("OxEDC6…").

**The signature is the woven ribbon.** A basket's holdings are shown as
proportional bands, by value at the reference price, with a faint weave
texture. A thinner, plain ribbon below shows the plan for new money. These are
the two things people confused in version 1: "what it holds" and "how new money
is split". They are now visibly different objects. The ribbon animates in once
on load; `prefers-reduced-motion` turns that off.

**The basket first, the machinery second.**
- The hero shows a real basket read from the chain, not an illustration.
- Your baskets come before everyone else's.
- Setup (test ETH, rUSDG, leftover spending permissions) moved into a wallet
  panel. It opens by itself only when something a purchase needs is missing.
- Price status is a small chip in the top bar. The long explanation of what the
  testnet prices can and cannot protect is one click away, and none of it is
  hidden: every buy panel states the age of the prices and links to that
  explanation.

**A page per basket** (`?basket=101`). It shows holdings with values, the plan
and its version, and a history read from contract events: created, added to,
handed on, copied, taken out, plan changed, each with its receipt. Its actions
depend on who is looking:
- **anyone** can add money and copy the plan;
- **the owner** can also take tokens out, hand the basket on and change the
  plan;
- **a visitor** is told who the owner is and why the other actions are not
  there.

On a phone the actions move up to follow the holdings, instead of sitting
below the whole history.

**Outcomes that change who can act are shown above the basket.** Examples are
a hand-over, or taking out the last holding. Showing them inside a panel that
disappears would hide the confirmation.

**Errors say what to do.** For example, too little rUSDG is refused before any
transaction, with the balance and how to get more. Contract refusals are
decoded into plain language, with the raw error folded away.

## States checked

- Disconnected, connected, owner, visitor: screenshots above.
- Closed basket: the page says so, lists its history, and offers no actions.
- Buying paused (prices expired): `after/desktop-basket-paused-local.png`.
  This was taken on the **local demo** after skipping 48 hours of chain time,
  which runs the same page code as the live site. The chip turns amber, every
  buy panel says why buying is paused and that taking out and handing on still
  work, and the buy buttons are disabled. In that same state, taking out a
  quarter of the basket worked ("Sent 0.011729 AAPL and 0.013293 NVDA").
- Error: `after/desktop-error-insufficient.png`.
- Phone width (390 px): no horizontal scrolling, and tap targets are at least
  36 px (44 px for primary buttons).

## Version 3: the living basket (2026-09-25)

The rule: **the page moves only on real state.**

| State | What the page shows | Screenshot |
|---|---|---|
| Before signing | who receives an addition ("Goes to … the owner now; if the basket changes hands first, it is refused"); a dashed ribbon of the basket *after* the addition, and "+ about …" per row, both from the contract's own `previewContribute` and labelled as estimates | `after/v3-visitor-estimate.png` |
| Signing and pending | each real step: permission (exact amount, or "already allowed"), confirm in wallet, waiting for the chain with a receipt link | `after/v3-addition-confirmed.png` |
| Confirmed | changed rows flash, amounts count up to the **actual** amounts, the new history entry slides in, and the result says "Bought 0.003749 TSLA (estimate 0.003772)" | `after/v3-addition-confirmed.png` |
| Refused | plain words, nothing spent; a stale owner is caught **before any permission is asked**, so it costs no transaction at all | — |
| Start in kind | the wallet's Stock Tokens with "All" buttons, a plan suggested from their value, and a note that no price is needed | `after/v3-start-in-kind.png` |
| Phone | actions follow the holdings | `after/v3-mobile-basket.png` |

`prefers-reduced-motion` turns off the flash, the counting and the slide. An
estimate is never drawn like a holding: it is dashed, faded, and says so.
