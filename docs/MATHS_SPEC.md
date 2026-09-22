# Jayo / HookFence — reference pricing specification

Formulas, units, rounding choices and assumptions for
`StockTokenReferencePolicy`. Every worked example below was derived from the
economics **independently of the implementation**, then asserted against it in
`test/unit/PricingSpec.t.sol`.

This matters because a round-trip test cannot catch a mistake made symmetrically
in both directions. A spec with externally-derived absolute values can.

---

## 1. Quantities and units

| Symbol | Meaning | Units |
|---|---|---|
| `amountIn` | input amount | raw units of the input token |
| `stockDec` | `IERC20(stockToken).decimals()` | — |
| `quoteDec` | settlement asset decimals | — |
| `stockPrice` | Chainlink `<STOCK>/USD` answer | scaled by `10^stockFeedDec` |
| `quotePrice` | Chainlink `<QUOTE>/USD` answer | scaled by `10^quoteFeedDec` |
| `stockFeedDec` | `IAggregatorV3(stockFeed).decimals()` | — |
| `quoteFeedDec` | `IAggregatorV3(quoteFeed).decimals()` | — |

**All decimals are read from the contracts, never assumed.** On Robinhood Chain
today `stockDec = 18`, `quoteDec = 6` (USDG), and both feeds report `8` — but
nothing in the implementation depends on those values, and §4 exercises other
combinations to prove it.

`MAX_DECIMALS = 27` bounds any exponent used in fixed-point arithmetic.

---

## 2. The two legs

Both legs are the same two steps — value the input in USD, then convert that USD
into the output token. Only which feed prices which side swaps.

### SELL — Stock Token in, settlement asset out

```
usd = amountIn · stockPrice / 10^stockDec                      [scaled 10^stockFeedDec]
out = usd · 10^quoteDec · 10^quoteFeedDec
      ────────────────────────────────────                     [raw quote units]
        10^stockFeedDec · quotePrice
```

### BUY — settlement asset in, Stock Token out

```
usd = amountIn · quotePrice / 10^quoteDec                      [scaled 10^quoteFeedDec]
out = usd · 10^stockDec · 10^stockFeedDec
      ────────────────────────────────────                     [raw stock units]
        10^quoteFeedDec · stockPrice
```

Each step is one `Math.mulDiv`, so intermediates are evaluated at 512-bit width
and no product has to fit in 256 bits. Only the final result must.

---

## 3. Rounding

`Math.mulDiv` **truncates toward zero**. Applied twice per leg, so a derived
value is understated by at most 2 raw units of the output token.

This direction is deliberate. The derived number is a **minimum acceptable
output**, so understating it can at worst let through a fill that is 2 raw units
below the mathematically exact floor — economically nil (2e-6 USDG, or 2e-18 of a
Stock Token). Overstating it would reject honest fills.

The permitted shortfall is then applied, also truncating:

```
referenceFloor = referenceOut · (10000 − maxShortfallBps) / 10000
floor          = max(userMinOut, referenceFloor)
```

**Invariant:** a round trip can never manufacture value. Valuing X into the other
asset and back yields ≤ X. Fuzz-tested over price and size in
`BuySidePolicy.t.sol::testFuzz_RoundTripNeverManufacturesValue`.

---

## 4. Worked examples

Derived by hand from the economics. Asserted in `PricingSpec.t.sol`.

### 4.1 Standard configuration

`stockDec = 18`, `quoteDec = 6`, both feeds `8`.
Stock at **$255.00** (`25500000000`), quote at **$1.00** (`100000000`).

**BUY 2,550.000000 USDG:**

```
usd = 2550000000 · 1e8 / 1e6           = 2.55e11      → $2,550 ✓
out = 2.55e11 · (1e18 · 1e8) / (1e8 · 2.55e10)
    = 2.55e11 · 1e26 / 2.55e18         = 1e19         → 10.000000000000000000 tokens
```

Sanity: $2,550 ÷ $255 = 10 tokens. ✓

**SELL 10 Stock Tokens** → `2550000000` = 2,550.000000 USDG. ✓

### 4.2 Unusual decimals — proves nothing is hardcoded

`stockDec = 8`, `quoteDec = 18`, `stockFeedDec = 18`, `quoteFeedDec = 6`.
Stock at **$50.00** (`5e19`), quote at **$2.00** (`2e6`).

**BUY 100 quote tokens** (`1e20` raw):

```
usd = 1e20 · 2e6 / 1e18                = 2e8          → $200 ✓   (100 × $2)
out = 2e8 · (1e8 · 1e18) / (1e6 · 5e19)
    = 2e8 · 1e26 / 5e25                = 4e8          → 4.00000000 stock tokens
```

Sanity: $200 ÷ $50 = 4 tokens. ✓

**SELL 4 Stock Tokens** (`4e8` raw):

```
usd = 4e8 · 5e19 / 1e8                 = 2e20         → $200 ✓
out = 2e20 · (1e18 · 1e6) / (1e18 · 2e6)
    = 2e20 · 1e24 / 2e24               = 1e20         → 100 quote tokens
```

Sanity: $200 ÷ $2 = 100 tokens. ✓

### 4.3 Rounding boundary — smallest non-zero input

Standard configuration. **BUY 1 raw USDG unit** (0.000001 USDG):

```
usd = 1 · 1e8 / 1e6                    = 100          → $0.000001
out = 100 · 1e26 / 2.55e18             = 3921568627   (exact: 3921568627.45…, truncated)
```

Truncation loses 0.45 raw units — 4.5e-28 of a token.

### 4.4 Multiplier is absent from both legs

The Chainlink Stock Token feed **already returns share price × `uiMultiplier`**,
i.e. the price of one whole token. Applying it again double-counts every
reinvested dividend and every split.

`uiMultiplier` appears nowhere in §2. Changing it, with the feed held fixed,
must not move any derived value — asserted on **both** legs, because applying it
to one leg only would be worse than applying it to both: the round-trip
invariant in §3 would then fail loudly rather than silently mispricing.

Source: <https://docs.robinhood.com/chain/oracles-and-price-feeds>

---

## 5. Validity preconditions

A value is derived **only if** all hold. Any failure reverts with a distinct
custom error; nothing is clamped or defaulted.

| Check | Error |
|---|---|
| `answer > 0` | `FeedAnswerNotPositive` |
| `updatedAt != 0` | `FeedRoundIncomplete` |
| `updatedAt <= block.timestamp` | `FeedTimestampInFuture` |
| `block.timestamp − updatedAt <= maxStaleness` | `FeedStale` |
| `!stockToken.oraclePaused()` | `OraclePausedForCorporateAction` |
| outside `[effectiveAt ± corporateActionBuffer]` | `CorporateActionPending` |
| sequencer up + past grace (only if a feed is configured) | `SequencerDown` / `SequencerGracePeriodNotOver` |
| `decimals <= MAX_DECIMALS` | `DecimalsOutOfRange` |

**These are identical on both legs.** A stale feed, an issuer pause or a
corporate-action window makes a Stock Token *untradeable*, not merely
*un-sellable*.

### 5.1 Deliberately not checked

`answeredInRound >= roundId` is **not** checked. Chainlink has deprecated the
field; on current aggregators it carries no information and treating it as a
liveness signal is a known false-positive source. Freshness is enforced by
`updatedAt` against the configured heartbeat instead.

---

## 6. Direction resolution

Direction is derived from reviewed configuration, never supplied by the caller.

```
inIsStock  = _stockTokens[tokenIn].feed  != 0
outIsStock = _stockTokens[tokenOut].feed != 0

inIsStock && !outIsStock  → SELL, instrument = tokenIn   (tokenOut must be a quote asset)
outIsStock && !inIsStock  → BUY,  instrument = tokenOut  (tokenIn must be a quote asset)
otherwise                 → revert TokenNotSupported
```

Stock-for-stock is rejected: it would require two instrument checks and a cross
rate, and is not a reviewed route.

A caller-supplied direction flag was considered and rejected — a caller could
declare it wrongly, whereas configuration cannot be spoofed.

---

## 7. Assumptions, stated so they can be challenged

1. **The feed is the reference of record.** Where the pool and the feed disagree,
   the feed is taken as correct. Consequence: when the feed is unavailable, no
   reference exists and pricing-dependent operations fail closed. This is why
   in-kind redemption must not depend on the policy.
2. **`oraclePaused()` is advisory.** Robinhood documents it as not enforced
   on-chain, so a paused oracle may still return a value. Staleness remains the
   primary guard; the flag is an additional fail-closed signal.
3. **Corporate actions can be reversed.** Observed on mainnet: WEEK had a 2:1
   multiplier applied and retracted 15 minutes later. The buffer therefore
   applies on **both** sides of `effectiveAt`.
4. **No sequencer uptime feed exists for Robinhood Chain** in Chainlink's
   published directory as of 2026-09-20, so that check is disabled unless an
   operator supplies a feed rather than pointed at a fabricated address.
5. **Decimals may change.** Cached at configuration time and re-read live; a
   mismatch is an operator error requiring reconfiguration, which bumps
   `policyVersion` and invalidates in-flight intents.
