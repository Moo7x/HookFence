# What Jayo costs on Robinhood Chain mainnet state — and what it refuses

**Measured 2026-09-24 on a fork of chain 4663.** Nothing was broadcast. Every
number below comes from `contracts/test/fork/MainnetForkCost.t.sol`; pin the block
to reproduce it:

```bash
cd contracts
MAINNET_FORK_BLOCK=71413360 forge test --match-contract MainnetForkCost -vv
```

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

Every refusal is checked against the policy's exact floor, not a rounded
percentage: at each refused size a direct swap of the AMZN leg really would have
delivered less than the floor. The limit is the AMZN pool's depth; the TSLA leg
alone stays inside the floor even at 25,000 USDG.

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
| Price check against an independent reference | yes, per leg; refused when the pool is off | none |
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
- **What the extra gas buys is the independent price check**, and run 2 shows it
  doing real work on live mainnet state.

## Not measured

- The L1 data fee on mainnet (it was measured only on testnet).
- A production router (Universal Router) as the manual baseline — v4's reference
  swap router was used; a production router adds its own overhead.
- HoodETF's gas or pool routing: nothing published, nothing measured. Its fees
  are documented (entry ≤3%, management ≤3%/yr, exit ≤1%) and are compared in
  `docs/COMPETITIVE_READ.md`.
