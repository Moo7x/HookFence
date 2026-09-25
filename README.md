# Jayo

**Build a funded token basket, own and transfer it as one position, copy its
allocation using your own funds, and withdraw its underlying assets.**

Jayo runs on Robinhood Chain and buys each leg of a basket through Uniswap v4.
Every basket is an NFT that holds its tokens itself. Whoever owns the NFT can
withdraw everything, a fraction, or a single asset, in kind. Anyone can copy a
basket's allocation once, using their own funds. Each purchase is checked
against a reference price, and a leg that fills below its floor reverts the
whole purchase. The execution engine underneath is HookFence.

Built for the Arbitrum Open House Singapore buildathon.

> **Testnet only.** The deployed contracts are on Robinhood Chain **testnet**
> (chain 46630). The tokens there are test assets with no value. rUSDG is a
> public test token that anyone can mint; it is not Paxos USDG. Nothing here has
> been audited.

## Where things are

| | |
|---|---|
| Live contracts and the two-wallet journey, with receipts | [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md), [docs/evidence/](docs/evidence/) |
| Public site: build, security headers, supervised sessions | [docs/PUBLIC_SITE.md](docs/PUBLIC_SITE.md) |
| Cost against doing it by hand, on a mainnet fork with Chainlink feeds | [docs/MAINNET_FORK_COST.md](docs/MAINNET_FORK_COST.md) |
| How Jayo compares with other basket products | [docs/COMPETITIVE_READ.md](docs/COMPETITIVE_READ.md) |
| Design | [docs/JAYO_DESIGN.md](docs/JAYO_DESIGN.md) |
| Contracts | [contracts/src](contracts/src) |
| Web app | [app/](app/) |

**Testnet deployment** (the full list is in
[deployments/robinhood-testnet.json](deployments/robinhood-testnet.json)):
JayoBasket `0xff5c76EAc645cb07317c95215B382909b9A00218`, ExecutionGateway
`0x8bae4Bc2B97D607a4409F74a708FeDFA2b43d01e`.

## Price references: what they do and don't protect

- **Testnet:** the reference prices are read from the same pools Jayo trades
  in. They stop a purchase from filling far below the last published price.
  They cannot tell whether the pool itself is fairly priced. The feeds expire
  after an hour. Once they have, buying is paused, but withdrawals keep working.
- **Mainnet fork test:** the reference comes from Chainlink's independent feeds.

## Run it

```bash
./scripts/run-demo.sh                     # local chain, mock assets, app at http://127.0.0.1:5173
cd contracts && forge test                # contract tests
node --test app/*.test.mjs scripts/*.test.mjs
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
