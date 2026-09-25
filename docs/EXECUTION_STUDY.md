# Stock Token execution on Robinhood Chain mainnet: is there a user loss to fix?

**Date:** 2026-09-25 · **Scope:** bounded, read-only · **Verdict: NO-GO on an execution product**

The question: do people trading Stock Tokens on mainnet get measurably worse
prices than was available to them, by enough to build a product around? Each
point below is labelled **[measured]** or **[hypothesis]**.

## 1. Verified addresses

Token identity was checked on chain with `symbol()` and `name()`. Feed identity
was checked on chain with `description()`, and the addresses come from the
Chainlink directory `feeds-robinhood-mainnet.json`. All feeds have 8 decimals.

| Asset | Token (mainnet 4663) | Chainlink feed | Feed description |
|---|---|---|---|
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` | RHTSLA / USD |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | RHNVDA / USD |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | Robinhood AAPL / USD |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` | Robinhood AMZN / USD |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | `0xF6f373a037c30F0e5010d854385cA89185AE638b` | Robinhood GOOGL / USD |
| **QQQ** | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` | Robinhood QQQ / USD |
| ETH | native / WETH | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | ETH / USD |
| USDG, USDC | `0x5fc5…d168` (USDG) | `0x61B7…9aD2`, `0x9e6f…2546` | USDG / USD, USDC / USD |

- Uniswap v4 PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- The Stock Token feeds have a **0.5% deviation threshold and a 24 h heartbeat**,
  and they update 24/5.
- `uiMultiplier` (selector `0xa60bf13d`) was at most 1.00078 for all six tokens.

## 2. Sampling and exclusions

The public RPC is non-archive and rate-limited, so this is a **described
sample**, not a census.

| Sample | Windows | Transactions |
|---|---|---|
| **A: week, off-hours** | 14 windows of 2,000 blocks (~3.4 min), about every 12 h: Fri 18 22:37 UTC through Fri 25 10:05 UTC. Because of the spacing, every window fell at about 10:00 or 22:00 UTC, **outside the regular US session**. | all 2,283 |
| **B: chosen times** | 12 windows of 2,000 blocks: Mon 21 00:08 (feed restart after the weekend), Mon 13:34 (open), 13:50, 16:00, 19:57; Tue 15:00, 18:30; Wed 14:59, 18:30; Thu 13:34 (open), 15:00, 18:30 UTC | 5,762 found; **a deterministic 25% subsample** (hash ending 0–3) = 1,501 |

**What is included.** Any transaction that moved one of the six Stock Tokens
into or out of the v4 PoolManager. In sample A, UniswapX `Fill` transactions
involving them were added as well.

**What is not seen:**
- UniswapX fills in sample B;
- venues other than Uniswap v4;
- other Stock Tokens;
- native ETH paid out through internal transfers.

**Who the user is.** The user is taken to be the address, other than the
PoolManager and pool hooks, with the largest change in Stock Token balance. For
UniswapX fills it is the swapper. Relayers and smart accounts mean this is often
not `tx.from`.

**How a price is computed.**
- **Price paid** = the net USD counter-leg ÷ shares, where shares = raw amount ×
  `uiMultiplier` / 1e18.
- **Counter-leg values:** USDG and USDC are valued at $1. WETH and ETH are valued
  at Chainlink ETH/USD at that block.
- **Reference:** the last Chainlink `AnswerUpdated` before the block. Because of
  the deviation threshold, this reference carries up to about ±50 bps of noise.

**Classification of all 3,784 sampled transactions [measured]:**

| Classification | Transactions |
|---|---|
| Priced buys and sells | 2,503 (2,415 at $1 or more after exclusions) |
| Counter-asset unpriced (memecoins, other stocks) | 713 |
| No counter-leg visible | 309 |
| No user-level Stock Token change (arbitrage or pass-through) | 192 |
| Other | 68 |

**Excluded by hand audit:** `0x329f2f8c…0303`. The classifier read it as a TSLA
buy 25.5% over Chainlink. It is actually a three-party multicall involving a
third token (liquidity or vault accounting); its swaps inside filled at about
$375.1, which is the market price.

## 3. Results by session and size [measured]

**How to read the bps columns:**
- For a buy, + means the user paid more than Chainlink. For a sell, + means the
  user received less.
- Regular session = Mon–Fri 09:30–16:00 ET. Weekend = the feed frozen, from Fri
  20:00 ET to Sun 20:00 ET.

| Session | Size | Trades | Volume | Median bps vs Chainlink, buys / sells | Vol-weighted bps | Trades with a peer | Worse than peer by >25 bps | Observed difference vs peers |
|---|---|---|---|---|---|---|---|---|
| regular | $1–100 | 518 | $17,257 | −2 / −6 | −2.1 | 466 | 134 | $22.66 (15.2 bps) |
| regular | $100–1k | 324 | $103,641 | −2 / −7 | 1.6 | 232 | 43 | $60.34 (9.5 bps) |
| regular | $1k–10k | 48 | $100,524 | 1 / 5 | 14.4 | 15 | 2 | $20.72 (8.8 bps) |
| regular | $10k+ | 3 | $63,936 | 56 / 22 | 19.1 | 0 | 0 | — |
| extended | $1–100 | 689 | $23,229 | −2 / −2 | −0.2 | 604 | 145 | $31.18 (15.4 bps) |
| extended | $100–1k | 521 | $151,068 | −5 / 2 | −4.3 | 401 | 50 | $80.44 (7.5 bps) |
| extended | $1k–10k | 61 | $116,597 | −2 / −23 | −6.6 | 19 | 2 | $10.20 (3.7 bps) |
| extended | $10k+ | 1 | $10,000 | 1 / — | 1.5 | 0 | 0 | — |
| weekend | $1–100 | 161 | $5,681 | −26 / 18 | n/a (frozen) | 127 | 4 | $2.50 (5.6 bps) |
| weekend | $100–1k | 74 | $26,766 | −19 / 9 | n/a | 39 | 0 | $1.37 (1.2 bps) |
| weekend | $1k–10k | 14 | $30,794 | −11 / 78 | n/a | 1 | 0 | $0.00 |
| weekend | $10k+ | 1 | $18,500 | — / 18 | n/a | 0 | 0 | — |

**Across all sessions:**
- 1,904 trades had a peer (§4), covering $274,118 of volume.
- The **observed difference vs peers totals $229.40** (8.4 bps), about **$0.12
  per trade**.
- **The largest single difference was $6.87.**
- The median gas cost per trade was **$0.08**.

**Every major router lands in the same place [measured]** (median buy / sell bps
vs Chainlink, outside weekends):

| Router | Median buy / sell (bps) | Trades |
|---|---|---|
| `0x6505…40dc` | −9 / −4 | 478 |
| relayer `0xccc8…15be` | +16 / −5 | 312 |
| ERC-4337 EntryPoint | −1 / −18 | 256 |
| Uniswap UniversalRouter `0x8876…0904` | −2 / −1 | 49 |
| 0x AllowanceHolder | +1 / −7 | 32 |

The only routers with a consistently worse median (+23 to +61 bps) are small:
18–38 trades each.

**UniswapX is live [measured].**
- 10,984 fills in the 7 days to 25 Sep, across 3 reactors; 10,938 of them went
  through `0x0000…7a1c…3cba`.
- 21 of 120 sampled fills involved one of the six Stock Tokens.

**The weekend of 19–20 Sep [measured, one weekend]:**
- The feed was frozen for about 50 h.
- Weekend DEX fills stayed within −0.42% to +0.76% of Friday's last print.
- The first print after the feed restarted, Mon 00:00 UTC, differed from Friday's
  by +0.04% to +0.44%.

**Lending against Stock Tokens [measured]:**
- **Morpho** `0x9d53…1010` has 62 markets with the six tokens as collateral. They
  hold about **$578k of USDG supplied against about $1.3k borrowed**. There have
  been 2 liquidations ever, and no bad debt.
- **26 Aave-style deployments:**
  - the largest USDG deposit is $28k, with about $0 borrowed;
  - the largest borrow anywhere is $146.
- **Compound-style and Euler listings exist but were not measured**, so their
  usage is **unknown**.

## 4. What the peer comparison can and cannot prove

**Definition.** A trade's *peer* is any other trade in the same token and
direction, **at least as large**, within 300 blocks (about 30 s). The *observed
difference* is how much worse this trade filled than its best peer, measured
against the same Chainlink reference. It is not called a loss.

**It can show:**
- that someone obtained a better price at the same or larger size, at almost the
  same time;
- that routers do not differ systematically;
- an **upper bound** on what better routing could have recovered within these
  windows: $229 on $274k.

**It cannot prove that the better price was available to *this* trade at *its*
block:**
- the peer may have traded first and moved the price;
- the peer may have used an RFQ or a private route not open to everyone;
- the state inside the block depends on ordering.

It also does not net out gas: peers sometimes paid more gas, up to $0.86 against
$0.08. No historical re-quote was possible, because the public RPC has no
archive state. Today's 0x or Relay quotes were **not** used as evidence for last
week.

**Other limits:**
- There is about ±50 bps of reference noise in the "vs Chainlink" columns. The
  peer test cancels most of it, because both trades use the same reference.
- The samples cover about 1.5 h of trading. Sample B is a 25% subsample.
- One weekend, and a calm one.

## 5. Corrections to earlier statements

1. **"SPY" was QQQ.** `0xD5f3…de68` is Invesco QQQ. `scripts/census-equity-pool-hooks.mjs`
   and `scripts/scan-holder-overlap.mjs` label it SPY. So does fact 4 in
   `FINDINGS_LOG.md` ("SPY … have NO sustained USDG liquidity"), and that fact is
   really about QQQ. The "SPY trades 3–5.8% below Chainlink" reported during this
   study came from comparing QQQ fills with the SPY feed. **There is no such
   dislocation:** QQQ fills sat within a few bps of the QQQ feed.
2. **"Buyers pay +30–49 bps, sellers −33–44 bps"** came from one window (Fri 25,
   09:45 UTC) and was not representative. Across the week, the medians are within
   ±10 bps.
3. **"A TSLA buy 25.5% over Chainlink"** was the misclassified multicall in §2.
4. The first analysis run read `uiMultiplier` with a wrong selector and fell back
   to 1.0. This was fixed before any table here was produced.

## 6. Go / no-go

**NO-GO on an execution product: routing, oracle-checked swaps, or an RFQ layer
for these Stock Tokens.**

What such a product could have changed for these trades, beyond what existing
routes already achieve:
- **[measured]** At most, closing the gap to the best same-size peer: about
  **$0.12 per trade, 8 bps**. That is roughly the median gas cost of the trade
  itself.
- **[measured]** The peers that set the benchmark were themselves routed by the
  same UniversalRouter, 0x, relayers and smart-wallet flows. The better price was
  reachable through tools that already exist.
- **[measured]** An oracle floor like Jayo's or HookFence's would have refused
  almost none of these trades during regular or extended hours. Where it would
  refuse, at weekends or in the first minutes after the open, the feed is the
  stale side, not the pool.
- **[hypothesis, untested]** A volatile weekend could produce large gaps between
  a frozen feed and DEX prices. One calm weekend neither supports nor rules this
  out, and borrowing against Stock Tokens is currently too small for weekend gaps
  to cause losses there.

## Reproducing

The scripts are in `research/execution-study/`, and the derived data (per-trade
rows, Chainlink histories, Morpho markets, tables) is in `data/`. Raw receipts
are not committed (about 12 MB); `stage1.mjs` rebuilds them from the public RPC.

```bash
cd research/execution-study
OUT=sample7d.json WINDOWS=14 SPAN=2000 DAYS=7 node stage1.mjs   # sample A
node stage1ux.mjs                                              # add UniswapX fills
OUT=sampleRTH.json ENDS=68355983,68836063,68845666,68923510,69065512,69745192,69870715,70603535,70729009,71460078,71585384,71408690 SPAN=2000 node stage1.mjs
IN=sample7d.json node analyze.mjs && IN=sampleRTH.json node analyze.mjs
node summarize.mjs sample7d.rows.json sampleRTH.rows.json    # section 3 tables
node weekend.mjs; node morpho.mjs; node aave.mjs; node uniswapx.mjs
```

Sample A windows are counted back from the chain head, so a rerun on a later day
samples different blocks. Sample B is applied after `stage1.mjs` writes its
checkpoint: keep only hashes ending 0–3 in the checkpoint file, then resume.
