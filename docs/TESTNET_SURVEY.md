# Robinhood Chain testnet — what is actually there

**Chain 46630. Everything here was read from `https://rpc.testnet.chain.robinhood.com`
on 2026-09-23.** Every claim is reproducible with the command beside it, and the
whole journey is re-run as code by `contracts/test/fork/TestnetJourney.t.sol`.

```bash
cd contracts && forge test --match-contract TestnetJourney -vv
```

---

## 1. The short version

Jayo can run on public testnet with **one** mock left in it: the price feeds.
Everything else — the Uniswap v4 PoolManager, the equity tokens, the stablecoin,
the pool liquidity — is chain state we did not deploy.

| Piece | On testnet? | Address |
|---|---|---|
| Uniswap v4 PoolManager | **yes**, same address as mainnet | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Permit2 | yes | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| TSLA equity token (18 dp, ERC-8056) | yes | `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E` |
| AMZN equity token (18 dp, ERC-8056) | yes | `0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02` |
| rUSDG "Rehearsal USDG" (6 dp) | yes | `0x7C902600cb5bf24225DF1a77b333D84e03C1F210` |
| Hookless TSLA/rUSDG pool, fee 3000 | yes | id `0xa127342a…4305c9` |
| Hookless AMZN/rUSDG pool, fee 3000 | yes | id `0x36fa647e…7730f7` |
| Mainnet USDG / AAPL / Chainlink proxies | **no** — those addresses are empty | — |
| **Chainlink price feeds** | **no** | we deploy our own |

> **Correction to `PHASE0_EVIDENCE.md`.** That document recorded that the mainnet
> Uniswap v4 address returns no code on testnet. It does return code — 48,020
> bytes, identical to mainnet. The USDG, Stock Token and Chainlink *proxy*
> addresses are genuinely empty there; v4 is not.

---

## 2. Method

There is no published address list for this testnet, so the tokens were found by
reading the chain rather than by looking them up.

**Step 1 — enumerate pools.** Every v4 pool emits `Initialize` from the
PoolManager:

```bash
cast keccak "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
# 0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438
```

A full-range `eth_getLogs` for that topic is rejected — *"logs matched by query
exceeds limit of 10000"* — which is itself the first finding: this testnet has
more than ten thousand v4 pools.

**Step 2 — rank the currencies.** Over the most recent 400,000 blocks, 286 pools
were created. One token appears in 146 of them.

**Step 3 — identify them.** `symbol()`, `name()`, `decimals()`, then the
ERC-8056 reads.

**Step 4 — filter to usable routes.** Most of what is there is a memecoin
launchpad: all 4,500 pools paired with `tUSDG` carry the same hook
`0x6599e4d659f39017ae5008c1d1cad52a10152ac8`, and the deepest "equity" pools
turned out to be TSLA and AMZN against tokens named `rfer`, `vfd`, `123123`,
`666` and `Elon Posts a New`, at fee tiers of 8–9.9%. Those are other teams'
tests, not markets.

What survives the filter is two hookless 0.30% pools against `rUSDG`.

---

## 3. What the equity tokens do and do not implement

```bash
cast call 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E "uiMultiplier()(uint256)" \
  --rpc-url https://rpc.testnet.chain.robinhood.com
```

| Read | TSLA / AMZN on testnet | AAPL on mainnet |
|---|---|---|
| `decimals()` | 18 | 18 |
| `uiMultiplier()` | `1000000000000000000` | `1000566080061092436` |
| `newUIMultiplier()` | same | same |
| `effectiveAt()` | `0` | `1786720366` |
| `totalSupplyUI()` | `6191600000000000000000000` | present |
| `paused()` | `false` (ERC20Pausable) | — |
| **`oraclePaused()`** | **reverts** | `false` |

This single difference blocked the whole deployment. The policy called
`oraclePaused()` unconditionally, so on testnet it could not price a single
trade.

The repair is **not** a try/catch reading a revert as "not paused" — that would
convert every future failure of that call, on mainnet included, into a silent
all-clear on the one flag that says a corporate action is in progress. Instead
the policy probes the instrument once when an owner registers it, stores
`hasOraclePaused` / `hasCorporateActionData`, and emits them as
`StockTokenCapabilities`. At quote time an absent capability is skipped; a
capability that was present and has stopped answering reverts with
`InstrumentStateUnavailable`. *Absent* and *disappeared* are different facts and
no longer read the same. See `contracts/test/unit/InstrumentCapabilities.t.sol`.

`mint` on both equity tokens is access-controlled — we cannot print equity, we
buy it through the pool like anyone else. `mint(address,uint256)` on **rUSDG is
open to any caller**, so funding the demo needs no token faucet.

---

## 4. Prices: why the feeds are ours, and what that costs

Chainlink publishes a reference-data directory for Robinhood Chain **mainnet**
and none for testnet:

```bash
curl -o /dev/null -w "%{http_code}\n" \
  https://reference-data-directory.vercel.app/feeds-robinhood-testnet.json   # 404
curl -o /dev/null -w "%{http_code}\n" \
  https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json   # 200
```

Nine aggregators *are* live on testnet. Their own `description()` values say what
they are: `"RHNVDA / USD (mock)"`, `"RHSPY / USD (mock)"`, `"USDG / USD (mock)"`,
`"TEST ONLY Non-Canonical Manual ETH / USD"`, `"BABA / USD (testnet, updated by
the Han…)"`. Pointing a solvency-critical policy at another team's hackathon
fixture would be worse than deploying our own and saying so.

**Seeding our feeds from the real mainnet prices does not work either.** Read on
2026-09-23 from Chainlink on Robinhood Chain mainnet:

| | Chainlink mainnet | Testnet pool spot |
|---|---|---|
| TSLA | **$380.26** (`0x4A1166a659A55625345e9515b32adECea5547C38`) | ~$256 |
| AMZN | **$256.91** (`0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C`) | ~$191 |
| USDG | $1.00005 (`0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`) | — |

Two unrelated venues, about 30% apart. A reference taken from mainnet would
refuse every testnet trade for a reason that has nothing to do with the trade.

So `contracts/src/testnet/PoolPriceReader.sol` takes the price from the pool, and
the limitation is stated rather than buried:

> On testnet the reference is derived from the same venue it is checking. It
> still catches the LP fee and the price impact **of the trade being made** —
> which is what the thin testnet liquidity actually threatens. It **cannot**
> catch the venue being mispriced against the outside world. That second
> guarantee exists only on mainnet, where the feed is Chainlink's.

The two mainnet feed addresses above are real and were read successfully, so the
mainnet configuration is a change of constructor arguments, not new work.

---

## 5. Liquidity, and the size it allows

Read from the PoolManager with `extsload`:

| Pool | Active liquidity (virtual reserves) | LP fee |
|---|---|---|
| TSLA / rUSDG | ≈ 2,009 rUSDG / 7.96 TSLA | 0.30% |
| AMZN / rUSDG | ≈ 906 rUSDG / 4.97 AMZN | 0.30% |

Measured shortfall against the policy's reference, one TSLA leg, same block
(`test_MeasuredShortfallByLegSize`):

| rUSDG in | shortfall |
|---:|---:|
| 1 | 34 bps |
| 5 | 54 bps |
| 10 | **78 bps** |
| 50 | 269 bps |
| 200 | **refused** |

30 bps of that is the pool's own fee; the rest is impact.

The testnet deployment therefore sets `MAX_SHORTFALL_BPS = 300`, where a mainnet
deployment would use 50. **Raised deliberately, with the numbers, rather than
tuned until something passed.** The demonstration is unaffected: a 20 rUSDG
basket completes, and a 2,000 rUSDG basket against the same pool in the same
block is refused.

---

## 6. Cost

```
Estimated total gas used for script: 13,990,192
Estimated amount required:           0.00028 ETH   (base fee 0.01 gwei)
```

> **Superseded 2026-09-24.** The full stack, the whole journey and 30 feed refreshes cost 0.00028 ETH at 0.01 gwei including the L1 data fee, measured from receipts; budget **0.001 ETH** (see `scripts/estimate-testnet-cost.mjs`). An earlier figure here, 0.00028 ETH for deployment alone, came from a local simulation that omits the L1 data fee and misprices calls; the match between the two numbers is coincidence.

That is the whole stack: three feeds, policy, gateway, adapter, basket, routes.
Any faucet drip covers it many times over.

---

## 7. What a person has to do

Exactly three things. Everything else is scripted.

### 7.1 Create a dedicated throwaway wallet

```bash
./scripts/new-testnet-wallet.sh
```

Prints an address; writes the key to `contracts/.env`, which is git-ignored.
**Never paste a private key into a chat window, an issue, or a commit.**

### 7.2 Fund it with testnet ETH

A person is needed because every faucet is behind a browser flow with a captcha
or a social login. Any one of these works; all were reachable on 2026-09-23:

| Faucet | Status when checked |
|---|---|
| <https://faucet.testnet.chain.robinhood.com/> | reachable (rate-limited, HTTP 429) |
| <https://faucet.quicknode.com/robinhood/testnet> | HTTP 200 |
| <https://faucets.chain.link/robinhood-testnet> | HTTP 200 |

You need **at least 0.001 ETH** (derivation in `MANUAL_ACTIONS.md` §1).

Verify:

```bash
cast balance <ADDRESS> --rpc-url https://rpc.testnet.chain.robinhood.com
```

### 7.3 Nothing else

No token faucet: rUSDG mints to any caller and the deploy script mints 10,000
rUSDG to the deployer. No RPC key, no explorer key, no allowlist.

Then:

```bash
cd contracts
forge script script/DeployJayoTestnet.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
```

Addresses land in `contracts/reports/jayo-testnet.json`, which the interface
reads the same way it reads the local one.

---

## 8. What is still mock, stated plainly

| Component | Status |
|---|---|
| Uniswap v4 PoolManager | real, not ours |
| TSLA, AMZN equity tokens | real, not ours |
| rUSDG stablecoin | real, not ours |
| Pool liquidity | real, not ours |
| Basket, policy, gateway, adapter | ours, this is the submission |
| **Price feeds** | **mock — ours, because Chainlink publishes none on this testnet** |
| **Price reference independence** | **reduced on testnet** — derived from the pool being checked, not from an outside source. Full on mainnet. |

Neither rUSDG nor the testnet equity tokens are redeemable for anything. They
are not Paxos USDG and not Robinhood Stock Tokens. The interface says so on
every screen and must continue to.
