# Jayo — walkthrough, with what backs each claim

**Date:** 2026-09-23, testnet section updated 2026-09-24.

Two things exist right now, and they are different:

| | Runs today | Assets | Price feeds | Uniswap v4 |
|---|---|---|---|---|
| **Local demo** | yes, one command | mock | mock | real `v4-core` PoolManager |
| **Robinhood Chain testnet** | **live since 2026-09-24**, two-wallet journey on public receipts | real | ours (access-controlled, pool-derived) | real, at the mainnet address |

Nothing here is on mainnet and nothing here holds anything redeemable.

---

## 1. The local demo

```bash
./scripts/run-demo.sh
```

Starts anvil, deploys the whole stack with mock assets, serves the interface at
<http://127.0.0.1:5173>.

### The journey, screen by screen

**1. Build your basket.** Put in an amount, set the split, press *Check what I'd
get* — the page shows, per leg, what the reference price says you should receive
and the floor the contract will enforce. Press *Create basket*.

Behind it: `JayoBasket.create(allocation, usdgIn, deadline)`. Each leg is priced
by `StockTokenReferencePolicy` and executed through `ExecutionGateway` →
`V4ExactInputAdapter` → the real PoolManager. Any leg filling below its floor
reverts the whole creation — no half-built position can exist.

**2. Your baskets.** Read from `holdingsOf(tokenId)`, which is the contract's
ledger, not an estimate.

**3. Hand it to someone else.** Paste the recipient's address. It is validated
as you type (format, checksum, zero address, your own address, Jayo's own
contracts), then *Review hand-over* shows the full address and exactly what the
basket holds, and nothing is signed until you tick "I have checked this address"
and press *Give it away*. There is no pre-filled recipient.

Behind it: `safeTransferFrom`, so a contract that cannot hold ERC-721s makes the
hand-over revert instead of swallowing the basket. The old owner's withdraw
controls are then disabled, and the contract refuses them anyway.

**4. Copy this mix.** Creates a new basket with the same split, bought with the
copier's own money. The source keeps everything of theirs.

**5. Take the tokens out.** Either part of it — *All of my NVDA, and nothing
else*, *Half of every token* — or everything, which closes the basket.

### The one screen that makes the argument

With *Skip forward 48 hours* pressed, so every feed is past its heartbeat:

- *Create basket* → **refused**: "We cannot get a current price right now.
  Buying is paused until prices update — stock prices only update while markets
  are open."
- *All of my NVDA, and nothing else* → **completes**: "Sent 26.583133 NVDA to
  your wallet. The basket is still yours and still holds the rest. No price was
  needed for this."
- *Half of every token* → **completes**: "Sent 11.728036 AAPL to your wallet."

Same block, same chain, opposite outcomes, because one path reads a price and
the other reads a ledger. Both messages above are verbatim from a run on
2026-09-23.

The claim is not just demonstrated, it is enforced: `PartialRedeem.t.sol` and
`BasketDustAndFailure.t.sol` point the gateway at a `RevertingPolicy` whose every
function reverts, and all three withdrawal paths still work.

### Verify it independently

```bash
cd contracts && forge test            # 115 tests, no network needed
```

---

## 2. Robinhood Chain testnet (46630) — LIVE, deployed 2026-09-24

Every hash below is a receipt read from the public RPC; the full list of 29 is in
[`docs/evidence/testnet-2026-09-24.json`](evidence/testnet-2026-09-24.json).
Re-check any of them yourself:

```bash
cast receipt <hash> --rpc-url https://rpc.testnet.chain.robinhood.com
```

### Contracts

| | Address |
|---|---|
| JayoBasket | [`0xff5c76EAc645cb07317c95215B382909b9A00218`](https://explorer.testnet.chain.robinhood.com/address/0xff5c76EAc645cb07317c95215B382909b9A00218) |
| ExecutionGateway | `0x8bae4Bc2B97D607a4409F74a708FeDFA2b43d01e` |
| StockTokenReferencePolicy | `0xf32DfbF47Ce18bFCC56f0C4B8a914E278385044f` |
| V4ExactInputAdapter | `0x06E42d75a72FD0b6eBD93c07baa5BBdf07Eea236` |
| DemoPriceFeed TSLA / AMZN / rUSDG | `0x0E7fC99A…4F8c` / `0x06dfc263…30d8` / `0xC5155229…cE00` |
| Uniswap v4 PoolManager (not ours) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| TSLA / AMZN / rUSDG (not ours) | `0xC9f9…Bd4E` / `0x5884…9E02` / `0x7C90…F210` |

Deployment: 19 transactions, all status 1, **0.0001224 ETH** in fees (estimated
beforehand at 0.0001269). Checked live after deploying: the policy records that
TSLA has no `oraclePaused()`, the gateway and basket point at each other, the feeds
accept only the deployer, and a write to the TSLA feed from any other address
reverts `NotUpdater`.

### The two-wallet journey

Three separate wallets: a **deployer** (owns the contracts, writes the feeds, never
used as a user), **Alice** and **Bob** (ordinary users, funded by the deployer).

| # | Who | What | Receipt |
|---|---|---|---|
| 1 | Alice | approve rUSDG to the basket | [`0xb8e8ab4e…6725`](https://explorer.testnet.chain.robinhood.com/tx/0xb8e8ab4e3ea14a8c4772511bc2400976fc47d06a1f7d9ce8e1dceb721a8f6725) · success |
| 2 | Alice | **create basket A**: 20 rUSDG, 60% TSLA / 40% AMZN | [`0x61d4fd05…96ce`](https://explorer.testnet.chain.robinhood.com/tx/0x61d4fd057af452d469d9df08a94150d7d3fabd0b575dcda124961cbb0f6496ce) · success |
| 3 | Alice | **hand basket A to Bob** (`safeTransferFrom`) | [`0x68f074ee…c1bd4`](https://explorer.testnet.chain.robinhood.com/tx/0x68f074eebaab5d4fa03aef228c18b2ef1a024b29f5d304dfacd0772ab00c1bd4) · success |
| 4 | Alice | **tries to withdraw basket A** | [`0x20e87996…7b10`](https://explorer.testnet.chain.robinhood.com/tx/0x20e87996d1f2f13b2219a7a084beb58ec0e14702ceaaf1e9c3782bfdfb7e7b10) · **reverted** `NotPositionOwner(1, Alice)` |
| 5 | Alice | **copies A's recipe** with her own rUSDG into basket C | [`0x16815747…4623`](https://explorer.testnet.chain.robinhood.com/tx/0x168157471d8858706d21213f2dccef975f2ac4f7313279bce8660826e4314623) · success |
| 6 | Bob | **takes only the AMZN out of basket A** | [`0x086eccf0…bde5`](https://explorer.testnet.chain.robinhood.com/tx/0x086eccf03d2e057ef4e4ff1722c133652d037ec193ef1d985eb388f0dfd6bde5) · success |

Step 4 was sent as a real transaction on purpose, so the refusal is a permanent
receipt rather than a claim; it moved nothing (Alice still holds no TSLA, basket
A's holdings were unchanged).

State read from the chain afterwards:

| | Owner | Holds |
|---|---|---|
| Basket A (#1) | Bob | TSLA 0.046369 — the AMZN is gone, the TSLA stayed |
| Basket C (#2) | Alice | TSLA 0.018396, AMZN 0.016339 — same 60/40 recipe, its own holdings |
| Bob's wallet | — | AMZN 0.041339, delivered in kind |
| Basket contract | — | owes exactly what it holds, for both tokens |

Whole journey including funding the two wallets: 10 transactions, about
0.000022 ETH. Everything since the faucet: **0.000145 ETH**; 0.00958 ETH remains.

### What is still mocked

| | |
|---|---|
| Uniswap v4 PoolManager, the pools and their liquidity | **real** — not deployed by us |
| TSLA, AMZN equity tokens; rUSDG stablecoin | **real testnet tokens** — not deployed by us. rUSDG is *not* Paxos USDG and none of them is redeemable for anything |
| Jayo's contracts | ours — this is the submission |
| **Price feeds** | **ours** (`DemoPriceFeed`). Chainlink publishes none on this testnet. Only the deployer can write them; one update may move a price at most 10%; each expires after one hour |
| Price source for those feeds | **the same pools Jayo buys in** (`PoolPriceReader`) |

### What the testnet price policy protects, and what it cannot

It **does** protect a buyer from the pool's fee plus the price impact of their own
purchase: each leg must arrive within 3% of the feed's price, or the whole purchase
reverts before any money moves. It **does** stop buying when the feeds are older
than an hour, and it **does** stop anyone but the deployer from moving the
reference.

It **cannot** tell whether the pool itself is fairly priced. The reference is
copied from that pool, so if the pool is off, the reference is off by exactly the
same amount and the purchase goes through. On 23 September Chainlink's mainnet
feed had TSLA at $380.26 while this testnet pool priced it near $256; the testnet
policy cannot see that gap. On mainnet the reference is Chainlink's, and
`docs/MAINNET_FORK_COST.md` shows that check refusing a pool that had drifted
66 bps from it.

The 3% floor is wide because these pools are tiny (about 2,000 rUSDG of active
liquidity in TSLA's); a mainnet deployment uses 0.5%. Withdrawals never read a
price, so they work whether or not the feeds are fresh.

---

## 3. Everything that is still a mock, in one place

| | Local demo | Testnet |
|---|---|---|
| Uniswap v4 PoolManager | **real** (`v4-core`, deployed locally) | **real**, `0x8366a39C…0951`, not ours |
| Equity tokens | mock | **real**, not ours |
| Stablecoin | mock | **real**, not ours |
| Pool liquidity | mock, seeded by us | **real**, other people's |
| Basket, policy, gateway, adapter | ours — this is the submission | ours |
| Price feeds | **mock** | **mock** — Chainlink publishes none on this testnet |
| Reference independence | n/a | **reduced** — derived from the pool being checked. Full on mainnet, where Chainlink's Robinhood TSLA/USD and AMZN/USD feeds exist and were read. |

Neither the testnet rUSDG nor the testnet equity tokens are redeemable for
anything. They are not Paxos USDG and not Robinhood Stock Tokens.
