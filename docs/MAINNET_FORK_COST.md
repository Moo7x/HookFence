# What Jayo costs on Robinhood Chain mainnet state — and what it refuses

**Measured 2026-09-24 on a fork of chain 4663.** Nothing was broadcast. Every
number below comes from `contracts/test/fork/MainnetForkCost.t.sol`:

```bash
cd contracts
forge test --match-contract MainnetForkCost -vv                           # live state
MAINNET_FORK_BLOCK=71413360 forge test --match-contract MainnetForkCost -vv  # pinned
```

**Reproducing a pinned block needs an archive RPC.** The public endpoint
`rpc.mainnet.chain.robinhood.com` prunes historical state: a later run at block
71,413,360 failed with "historical state … is not available" the moment it
touched an account this machine had not already cached. The pinned figures below
were re-run from forge's local cache on this machine; anyone else needs an
archive endpoint (or runs at the live block and gets that block's numbers).

## Configuration — exactly what a mainnet deployment would use

| | |
|---|---|
| Stablecoin | Paxos USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Assets | canonical TSLA `0x322F…3b2d`, AMZN `0x12f1…bF54` ([registry](https://docs.robinhood.com/chain/contracts)) |
| Reference | **Chainlink's published Robinhood feeds** — independent of the pools. Not the pool-derived price the testnet has to use. |
| Floor | 50 bps below the Chainlink reference, per leg |
| Recipe | 60% TSLA / 40% AMZN |
| TSLA pool | hookless, 0.30%, ~10.0M USDG active, `0x8517…d32e` |
| AMZN pool | hookless, 0.24%, ~562k USDG active, `0xefc9…8825` |

Pools were chosen by `node scripts/find-routes.mjs mainnet TSLA AMZN`: the
deepest hookless USDG pool for each. Most USDG/equity pools on mainnet are not
usable — of 46 AMZN pools, 20 carry a hook, 15 are empty, and several of the rest
charge 77–90% fees or sit 390% off the real price.

The comparison is **Jayo** (one approval, then one `create` for both legs) against
a **manual flow** (one approval, then two direct swaps through the *same* pools
from the *same* starting state, via v4's reference swap router).

## Run 1 — L2 block 71,413,360 (Chainlink TSLA $377.89, AMZN $247.37)

| Basket (USDG) | Result | TSLA vs Chainlink | AMZN vs Chainlink | Jayo = direct swap? |
|---:|---|---:|---:|---|
| 20 | accepted | 19 bps below | 15 bps below | **identical, to the wei** |
| 1,000 | accepted | 20 | 22 | **identical** |
| 2,500 | accepted | 20 | 33 | **identical** |
| 5,000 | **refused** | 22 | just over 50 | — |
| 7,500 | refused | 23 | 68 | — |
| 10,000 | refused | 25 | 85 | — |
| 25,000 | refused | 34 | 189 | — |

Every refusal is asserted exactly. The test captures the revert data from
`create` and requires it to equal `OutputBelowFloor(received, required)` from the
gateway, for the first leg in execution order that a direct swap from the same
state shows would fill below its floor, with both amounts matching to the unit.
At every refused size here that leg is AMZN. The limit is the AMZN pool's depth;
the TSLA leg alone stays inside the floor even at 25,000 USDG.

## Run 2 — L2 block 71,417,436, a few minutes later (AMZN $246.11)

Chainlink's AMZN price fell 0.51% between the two blocks. The pool did not
follow. From then on a direct swap of even the 8 USDG AMZN leg came in **66 bps**
below the independent price, and **Jayo refused every size** — 20 USDG included.

| Basket (USDG) | TSLA | AMZN | Jayo |
|---:|---:|---:|---|
| 20 | 33 bps below | **66** | refused |
| 1,000 | 33 | 73 | refused |
| 10,000 | 39 | 136 | refused |

This is the case a pool-derived price cannot catch and an independent one can:
the venue was mispriced against the market, not moved by the trade. A user
swapping by hand would have filled; Jayo would not. Whether that is what the user
wants is a real product question — a 50 bps floor on a pool that lags the feed
will sometimes block a trade the user would accept — and the floor is a
per-asset setting, not a constant.

### Run 3 — L2 block 71,432,165 (live, about 25 minutes after run 1)

Still refused at every size, 20 USDG included, and every refusal again asserted
exactly as `OutputBelowFloor` on the AMZN leg. The pool had not come back to the
Chainlink price.

## Cost next to doing it by hand (run 1)

Execution gas from the fork, plus 21,000 intrinsic per transaction; priced at the
fork's base fee (0.0419 gwei) and Chainlink ETH/USD $2,664.10. The L1 data fee
this chain also charges is **not** included here (on testnet it added 4–12%, see
`scripts/estimate-testnet-cost.mjs`).

| Step | Jayo | Manual (two swaps) |
|---|---|---|
| Approve USDG | 1 tx · ~$0.008 | 1 tx · ~$0.008 |
| Buy both legs | **1 tx · 1,257,221 gas · ~$0.140** | 2 tx · 518,238 gas · ~$0.058 |
| Tokens received | identical | identical |
| Price check against an independent reference | yes, by default, per leg; refused when the pool is off | only if you compute a Chainlink-based minimum and pass it yourself |
| Hand the whole thing to someone | **1 tx (one NFT) · 117,281 gas · ~$0.013** | 2 tx (two tokens) · 205,592 gas · ~$0.023 |
| Recipient takes the tokens | 1 tx · 235,254 gas · ~$0.026 (in kind, no price) | already in their wallet |

Stated plainly:

- **Jayo is more expensive to buy with.** About 2.4× the gas of two direct swaps —
  the policy's Chainlink reads, the per-leg checks, the ledger and the NFT mint.
  At today's fees that is about eight cents more.
- **It gets exactly the same tokens.** Same pools, same state, no protocol fee:
  the amounts matched to the wei at every accepted size.
- **It is cheaper to hand over** — one transfer instead of one per asset — and
  what moves is one object with a recorded composition.
- **What the extra gas buys is the price check against an independent
  reference, applied by default to every leg** — and runs 2 and 3 show it doing
  real work on live mainnet state. It is a demonstrated benefit, not a unique
  one: Phase 0 (`docs/BASELINE_RESULTS.md`) showed an ordinary router given the
  same Chainlink-derived minimum refuses the same trades, and other products
  (HoodETF among them) use Chainlink for pricing. What Jayo adds is that the user
  does not have to compute or supply that minimum.

## If the recipient withdraws the tokens immediately

The full path when a basket is bought, handed to someone, and that person takes
the tokens out at once. Run 1, pinned block, base fee 0.042112 gwei, ETH $2,664.10
(Chainlink ETH/USD read the same day). Gas is execution plus 21,000 per
transaction; calldata cost and the L1 data fee are not included.

| Basket | Jayo: approve, create, hand over NFT, recipient redeems (4 tx) | Manual: approve, two swaps, two transfers (5 tx) | Jayo ÷ manual |
|---:|---|---|---:|
| 20 USDG | 1,691,802 gas · 0.0000713 ETH · **$0.19** | 805,924 gas · 0.0000339 ETH · **$0.09** | 2.10× |
| 1,000 USDG | 1,692,657 gas · $0.19 | 806,819 gas · $0.09 | 2.10× |
| 2,500 USDG | 1,698,530 gas · $0.19 | 812,706 gas · $0.09 | 2.09× |

The recipient ends up holding exactly the same TSLA and AMZN either way; the test
asserts it. So if the only goal is to give someone two tokens right now, doing it
by hand is about ten cents cheaper and one transaction longer. Jayo's case rests on
what happens before that: one object to hand over, a recorded composition, a price
check on the way in, and the option for the recipient to take out one asset and
leave the rest.

## Not measured

- The L1 data fee on mainnet (it was measured only on testnet).
- A production router (Universal Router) as the manual baseline — v4's reference
  swap router was used; a production router adds its own overhead.
- HoodETF's gas or pool routing: nothing published, nothing measured. Its fees
  are documented (entry ≤3%, management ≤3%/yr, exit ≤1%) and are compared in
  `docs/COMPETITIVE_READ.md`.

---

## Re-measured on version 2 (2026-09-25, L2 block 72,046,674)

Run with `forge test --match-contract MainnetForkCost -vv` at the latest block,
against JayoBasket version 2. The public RPC is not an archive node, so earlier
pinned blocks cannot be replayed; these figures replace the version-1 ones above
wherever cost is quoted.

**Prices at that block:** Chainlink TSLA $380.25, AMZN $250.11, ETH $2,677.24.
The base fee was 0.0385 gwei. Dollar figures cover L2 execution gas only; the
L1 data fee is not included.

| Path | Jayo v2 | By hand | Ratio |
|---|---|---|---|
| Buy a 60/40 basket, hand it over, recipient withdraws at once (20 USDG) | 1,750,776 gas, 4 tx (≈ $0.18) | 806,236 gas, 5 tx (≈ $0.08) | 2.17× |
| **Add 100 USDG to someone else's basket, split 60/40** | **1,055,251 gas, 2 tx (≈ $0.11)** | 797,680 gas, 5 tx: approve, 2 swaps, 2 transfers (≈ $0.08) | **1.32×** |

The two paths deliver exactly the same TSLA and AMZN to the recipient, and
the test asserts it (0.157146 TSLA and 0.159204 AMZN for the contribution).
Jayo takes no fee.

**Refusals moved with the market.** At this block every basket of 1,000 USDG
or more is refused by the 50 bps floor. At 1,000 USDG, a direct swap would get
0.41% less TSLA and 0.50% less AMZN than Chainlink's price implies, because the
pools trade slightly above Chainlink. On the earlier fork, 1,000 and 2,500 USDG
were accepted. The floor is doing its job, but the practical mainnet size
depends on the day's pool-to-feed gap.

**What this means for the product.** A one-off basket that is bought, handed on
and emptied straight away costs about twice doing it by hand, and should not be
sold as cheaper. Adding to an existing basket costs 1.3× the manual route, and
replaces five transactions and knowledge of the mix with one. The overhead is
smallest exactly where the product's case rests: repeated funding of a basket
that persists.
