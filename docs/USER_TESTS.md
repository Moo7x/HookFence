# Testing Jayo with people outside the project

Nobody outside the project has used version 2 yet. The assistant building it
cannot talk to people; this is a protocol for the owner to run with **two or
three people**, each for about 15 minutes. Watch, don't help: where someone
hesitates is the result.

## Before each session

- Use a laptop with a browser wallet (MetaMask or Rabby) holding a fresh test
  account with a little test ETH (faucet links are in the site's wallet panel).
- Check the price chip at the top of <https://jayo-testnet.pages.dev>. If it
  says "Buying paused", run `./scripts/keep-testnet-feeds-fresh.sh --once`
  (or deploy the keeper Worker, after which this is not needed).
- Have one basket of your own ready (for example #101-style: 60/40 TSLA/AMZN)
  and its link.

## Tasks (read them out; don't show the page first)

1. "A friend sent you this link [your basket's link]. Tell me what it is and
   whose it is."
   *Watch:* do they find the owner line and the holdings, and do they
   understand that the tokens have no value?
2. "Add 5 dollars to it as a gift."
   *Watch:* do they understand that the money buys the basket's plan and
   belongs to the owner? Do the two wallet prompts (permission, then purchase)
   confuse them?
3. "Now make your own basket with the same mix, with your own money."
   *Watch:* do they find "Copy plan"? Do they expect it to share the friend's
   basket instead?
4. Hand them the owner's wallet (or have them create a basket first).
   "Take out only the Tesla and keep the rest."
5. "Give this basket to [your second address]."
   *Watch:* the review-and-confirm step: too much, or reassuring?

## Ask afterwards (write down their words, not a summary)

- "Who would you use this with, if the stocks were real?"
- "What would you expect to happen if the owner changed the mix after you
  added money?"
- "What made you hesitate?"
- "Would you rather give someone this, or send them the stock directly? Why?"

## What would change the plan

- If people read "add money" as buying a share of the basket for themselves,
  the page's wording is wrong, and the product may need contributor receipts.
- If nobody can name someone they would give a basket to, the gifting case is
  weak. Test the "my own portfolio, topped up monthly" case instead.
- If copying is found faster than adding, the page is ordering the actions
  wrong.
