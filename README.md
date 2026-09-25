# Jayo

**Status: engineering prototype, not the project's product.** On 2026-09-25
the team concluded that a basket position has no user benefit strong enough to
beat holding the same Stock Tokens in one's own wallet
([docs/GO_NO_GO.md](docs/GO_NO_GO.md)). The contracts, tests and live testnet
site are kept as working engineering.

A Jayo basket is one NFT that holds a mix of Stock Tokens on Robinhood Chain,
bought through Uniswap v4. Its owner can withdraw everything, a fraction, or a
single stock, in kind, with no price needed, and can hand the whole basket on.

**Anyone can add to a basket.** Money is bought by *that basket's own plan*;
Stock Tokens someone already holds can be moved in directly, with no price
needed. Every addition names the owner the giver saw and is refused if the
basket has changed hands. The owner can change the plan for future money;
holdings are never rebalanced. A basket can also be started with Stock Tokens
already held, and anyone can start their own basket with another basket's
plan, paid with their own money.

Every basket has a page (`?basket=101`) and on-chain metadata showing its
holdings, plan and history. Each purchase is checked against a reference price,
and a stock that fills below its floor reverts the whole purchase. The execution
engine underneath is HookFence. Why this direction, and not a copy of existing
products: [docs/PRODUCT_DIRECTION.md](docs/PRODUCT_DIRECTION.md).

Built for the Arbitrum Open House Singapore buildathon.

> **Testnet only.** The deployed contracts are on Robinhood Chain **testnet**
> (chain 46630). The tokens there are test assets with no value. rUSDG is a
> public test token that anyone can mint; it is not Paxos USDG. Nothing here has
> been audited.

## Where things are

| | |
|---|---|
| Live site | <https://jayo-testnet.pages.dev> |
| Product direction: who it is for, compared with the alternatives | [docs/PRODUCT_DIRECTION.md](docs/PRODUCT_DIRECTION.md) |
| Each feature as a hypothesis, with evidence; the judging criteria | [docs/HYPOTHESES.md](docs/HYPOTHESES.md) |
| An independent review (Codex) and its verification | [docs/CODEX_INDEPENDENT_STRATEGY.md](docs/CODEX_INDEPENDENT_STRATEGY.md) |
| Public site, version 2 journey receipts, the scheduled price keeper | [docs/PUBLIC_SITE.md](docs/PUBLIC_SITE.md) |
| Interface redesign, before and after | [docs/design/README.md](docs/design/README.md) |
| Version 1 contracts and the first two-wallet journey | [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md), [docs/evidence/](docs/evidence/) |
| Cost against doing it by hand, on a mainnet fork with Chainlink feeds | [docs/MAINNET_FORK_COST.md](docs/MAINNET_FORK_COST.md) |
| How Jayo compares with other basket products | [docs/COMPETITIVE_READ.md](docs/COMPETITIVE_READ.md) |
| Design | [docs/JAYO_DESIGN.md](docs/JAYO_DESIGN.md) |
| Contracts | [contracts/src](contracts/src) |
| Web app | [app/](app/) |

**Testnet deployment** (the full list is in
[deployments/robinhood-testnet.json](deployments/robinhood-testnet.json)):
JayoBasket v3 `0xA4Bd059436717c2450e2aab636d3F3476455e529` (baskets from #201).
Versions 1 (`0xff5c76EA…0218`, #1–#7) and 2 (`0x1F0AB726…Ac0B`, #101–#102)
stay live, withdraw-only on chain: their baskets can still be taken out of and
handed on. ExecutionGateway `0x8bae4Bc2B97D607a4409F74a708FeDFA2b43d01e`.

## Price references: what they do and don't protect

- **Testnet:** the reference prices are read from the same pools Jayo trades
  in. They stop a purchase from filling far below the last published price.
  They cannot tell whether the pool itself is fairly priced. A scheduled
  keeper republishes them with a dedicated key that the feeds bound to one
  update per 15 minutes, 10% a step and 25% a day. They expire after an hour.
  Once they have, buying is paused, but withdrawals keep working.
- **Mainnet fork test:** the reference comes from Chainlink's independent feeds.

## Run it

```bash
./scripts/run-demo.sh                     # local chain, mock assets, app at http://127.0.0.1:5173
cd contracts && forge test                # contract tests
node --test app/*.test.mjs scripts/*.test.mjs keeper/src/*.test.mjs
node scripts/build-site.mjs               # public site -> site/dist (Cloudflare Pages)
```

The contract tests need [Foundry](https://getfoundry.sh). Clone with
`--recurse-submodules` so the contract libraries are included.

## Security notes

- The public site is static. Visitors sign every transaction in their own
  browser wallet. The site holds no keys and runs no signer. Scripts load only
  from the site itself.
- The build refuses to ship if its output contains a key, the local test signer,
  a localhost address, or an unexpected file.
- `python scripts/scan-git-history.py` checks every version of every committed
  file for secrets.
