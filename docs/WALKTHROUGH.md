# Jayo — walkthrough, with what backs each claim

**Date:** 2026-09-23.

Two things exist right now, and they are different:

| | Runs today | Assets | Price feeds | Uniswap v4 |
|---|---|---|---|---|
| **Local demo** | yes, one command | mock | mock | real `v4-core` PoolManager |
| **Robinhood Chain testnet** | proven on a fork, **deployment awaits a faucet drip** | real | mock | real, at the mainnet address |

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

**3. Hand it to someone else.** *Allow a manager first*, then *Hand over basket*.
The confirmation is the point:

> Basket #1 now belongs to 0x7099…79C8. You can no longer withdraw from it, and
> any manager you allowed has been removed.

Behind it: ERC-721 `_update` deletes `positionManager[tokenId]` and bumps
`positionVersion`, so a delegation cannot survive a sale. The old owner's
*Withdraw* button is then disabled, and the contract refuses them anyway.

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

## 2. Robinhood Chain testnet (46630)

`docs/TESTNET_SURVEY.md` is the full account. The short version: the PoolManager,
the TSLA and AMZN equity tokens, the rUSDG stablecoin and both 0.30% hookless
pools are real chain state we did not deploy. The price feeds are ours, because
Chainlink publishes no feed directory for this testnet.

### What is already proven, and reproducible by anyone

```bash
cd contracts && forge test --match-contract TestnetJourney -vv
```

Forks the live chain and runs the whole journey against it. Output from
2026-09-23:

```
TSLA pool price, 8dp: 25650238666        ($256.50)
AMZN pool price, 8dp: 19129864050        ($191.30)

test_TestnetEquityTokensDoNotAnswerOraclePaused   PASS
test_CreateBuysRealEquityThroughTheRealPoolManager PASS
   TSLA acquired (1e18): 38678680248537746        (0.038679 TSLA)
   AMZN acquired (1e18): 51563381006970258        (0.051563 AMZN)
test_WithdrawalWorksWithEveryFeedStale            PASS
test_OversizedBasketIsRefusedAgainstRealLiquidity PASS
test_CopyIsFundedByTheCopier                      PASS
test_MeasuredShortfallByLegSize                   PASS
   1 rUSDG ->  34 bps      50 rUSDG -> 269 bps
   5 rUSDG ->  54 bps     200 rUSDG -> refused
  10 rUSDG ->  78 bps
```

Those are real swaps against real pool liquidity, priced by the real PoolManager.
They are executed on a fork, so they are not broadcast transactions.

The deployment itself simulates end to end against live state:

```
Estimated total gas used for script: 13,990,192
Estimated amount required:           0.00028 ETH
```

### What is pending, and why

**A faucet drip of 0.0003 ETH into a dedicated throwaway wallet.** Every faucet
is behind a browser flow with a captcha or a social login, which a person has to
complete. That is the only blocker; see `MANUAL_ACTIONS.md` §1 for the three
faucets that were reachable on 2026-09-23.

Once it lands:

```bash
./scripts/new-testnet-wallet.sh            # writes the key to contracts/.env only
cd contracts
forge script script/DeployJayoTestnet.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
```

No token faucet is needed: rUSDG's `mint` is open to any caller and the script
funds the demo wallet itself. The interface picks the deployment up from
`contracts/reports/jayo-deployment.json` with no rebuild, switches to an injected
wallet because the chain is public, hides the demo panel because time travel
needs anvil, and changes its banner to *Testnet · mock price feeds*.

**Transaction hashes will be recorded here, from
`contracts/broadcast/DeployJayoTestnet.s.sol/46630/run-latest.json`, as soon as
that runs.** They are not in this document yet because the deployment has not
happened, and quoting simulated hashes as if they were broadcast would be a lie.

### Demo size on testnet

20 rUSDG, 10 a leg — measured at 78 bps against a 300 bps floor. This is small
because the pools are small: about 2,009 rUSDG in the TSLA pool's active range
and 906 in AMZN's. A 2,000 rUSDG basket against the same pool in the same block
is refused, which is the protection doing its job rather than a failure.

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
