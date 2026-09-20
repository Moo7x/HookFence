# Six ideas — pick one

**Generated:** 2026-09-20 · **Deadline:** 2026-10-04 15:59 UTC (~13 days)

From 5 web-research sweeps (Stylus, onchain gaming, the culture angle, sponsor intent,
and what actually wins hackathons), 15 generated ideas, scored and cut to 6.

Grounded in the measured chain facts in `docs/FINDINGS_LOG.md`.

---

## The 6

### 1. BLUE CHIP
**The pitch:** A Uniswap v4 hook that turns every memecoin trade into a raffle ticket and pays the jackpot in real shares of NVIDIA — ape the dog coin, win the company.

**What you build:**
- A v4 hook on memecoin/USDG (and memecoin/stock-token) pools that takes a small surcharge on the buy leg via the chain's live dynamic-fee mechanism, sweeps it to a house vault, and converts the vault into a blue-chip stock token (NVDA / SPY / SPCX).
- Ticket accounting: tickets weighted by USDG-equivalent swap size, per-swap cap so a whale can't buy the pot. This is balance-delta accounting — the thing your 42-test engine already does.
- Draw contract on commit-reveal randomness (user seed at swap time, operator seed revealed next block; ~200ms at 0.1s blocks). Verify VRF on chainId 4663 in hour one; if it's not there, commit-reveal and say so on stage.
- One page: pot denominated in shares AND dollars, live ticket feed scrolling as swaps land, your odds, countdown, hall of fame. Pot value reads `uiMultiplier` at payout, never cached at deposit.

**The demo moment:** Split screen. Left, a live pool with your hook, swaps landing every few seconds. Right, the pot ticking upward denominated in NVDA shares. You swap $5 of something absurd, your tickets appear, you trigger the draw — and 0.31 shares of NVIDIA land in a wallet that has never held anything but dog coins, visible in the explorer as a real stock-token transfer. Then: "Every other project here built a warning label for this chain. We built the part where the casino accidentally makes you an investor."

**Why it fits:** Uniswap v4 — a real hook with dynamic fees, delta accounting and atomic rollback, which is judging criterion #1 scored directly. Robinhood Chain — stock tokens as the prize, ERC-8056 handling on a live pot, plugs into the launchpad economy. Paxos — USDG is the ticket-weighting and fee-sweep rail, i.e. infrastructure inside the product, which is what Global Dollar Network actually rewards. Arbitrum — DeFi-meets-Gaming on the main track. Stylus — optional, ticket-weighting loop, off the critical path.

**Build:** 9 days. Hardest part: hooks bind at pool init and 94% of equity pools already carry someone else's hook, so you cannot install onto existing flow — you deploy your own pools (trivial here) and present that as an architectural choice with launchpads as the roadmap, not as a thing you missed.

**Honest weak spot:** Demo traffic is mostly yours, not organic. Answer: deploy 3-4 hooked pools on day 2, seed them, and drop one link in a degen Telegram so at least one stranger's wallet is on the winners board — then frame the thesis as harm reduction, converting compulsive memecoin gambling (79% of this chain's volume, unambiguously real) into forced equity accumulation. That's a real answer to "real problem solving," not a joke.

**Closest existing thing:** LotoHook / $loto on Ethereum (every swap a ticket, pot in ETH). PadFeeHook, already registered on this chain, ships an optional coin-flip game on buys. V2MemeHook already sweeps meme fees into a quote asset. Gifted Stock on Base pays out tokenized-stock slices at ~75% EV. Every component has shipped; the combination — swap lottery on a memecoin pool whose jackpot is real equity, on the one chain where both live in the same AMM — has not.

---

### 2. STOCK OR SLOP
**The pitch:** A 20-second party game where you look at an anonymized chart from this chain and guess: real company, or dog coin?

**What you build:**
- Round contract: commit-reveal. The contract commits `hash(pool, fromBlock, toBlock, salt)` before the chart is published; players commit hashed answers; everything reveals. Nobody, including you, can pick the chart after seeing the answers.
- The answer key, on-chain and oracle-free: staticcall `uiMultiplier()` on the token. NVDA returns a value, ROBOCLAW reverts. Ship the hardcoded ~194-address stock-token registry as the primary classifier (zero risk) and show the staticcall as the elegant verification path.
- Backfill script: pull v4 swap events per pool, normalize to a 0-100 index so the y-axis leaks nothing, reject series under N swaps. Precompute nightly; chain only ever stores the hash.
- Gasless one-tap entry: ERC-4337 session keys + Alchemy paymaster. Free daily solo streak mode is the front door; $1 USDG pari-mutuel and 1v1 duels sit behind it.

**The demo moment:** Put the chart up and let the judges vote out loud. They confidently say NVDA. Reveal: $ASS, 41 holders, nine days old. Then hit VERIFY and staticcall both token addresses live — NVDA returns 1.0043, ASS reverts. Everyone laughs, settlement fires, USDG lands in about a second.

**Why it fits:** Robinhood Chain — ERC-8056 as an on-chain answer key exists nowhere else, plus AA/gasless which almost nobody in the gallery touches. Paxos — USDG is entry and payout. Arbitrum — Gaming and Social, named in the brief, backed by $215M+. Uniswap v4 — all chart material derived from live pool swaps. Judging — innovation and memorability are unusually high for how small the contract surface is.

**Build:** 8 days. Hardest part: the chart pipeline, not the contracts. Thin memecoin pools produce ugly series; spend days 1-2 on the normalizer and rejection filter.

**Honest weak spot:** A $1 pari-mutuel cash game next to Robinhood and Paxos branding can read as gambling. Answer: lead with the free daily streak mode as the product, and say in one sentence that the staked mode is a skill competition — you're scoring pattern recognition, not price direction. Curate a hand-checked deck of ~20 clean charts for the live judge round so the verify moment always lands.

**Closest existing thing:** guessthestockchart.io and Bulliq are web2, single-player, equities-only, nothing on-chain. Hoot! (ETHRome 2025) is the nearest on-chain format. Flicky (Sui Overflow 2026) proved the swipe-deck winner-take-pot shape. The genre is not new; the material and the verifiable answer key are.

---

### 3. TICKER DERBY
**The pitch:** An eight-lane race every ten minutes where the horses are real tokens, the track is live market data, and SPY has to run against a coin called ASS.

**What you build:**
- Race factory: field of 8 committed one block before betting opens (five memecoins, three equities), drawn from top-volume pools above a liquidity floor.
- Bet escrow in USDG, pari-mutuel win/place, two-minute betting window, settlement as a pure function of price samples over a fixed block range that anyone can recompute.
- Price sampling: do NOT assume v4 pool oracles are populated — check observation cardinality on your candidate pools in hour one. If it's 1 (likely), have the contract or a keeper record spot samples at a fixed block interval during the race and compute returns from those. Still fully recomputable from chain events.
- The track: lane rendering interpolated at ~10fps off 0.1s blocks, plus a live swap-commentary strip ("ROBOCLAW takes the rail, 340 swaps this minute") and an odds board showing each runner's realized hourly volatility and pool depth.

**The demo moment:** Run a real race live on the judging call. They pick a runner, you place their bet gaslessly, and eight lanes twitch in real time off a chain producing ten blocks a second. Around minute six a memecoin nobody picked goes vertical and takes the field. Settlement fires, USDG lands, and you open the explorer to show the samples the contract used.

**Why it fits:** Robinhood Chain — 0.1s blocks are the animation clock; equities and memecoins in one field only exist here. Paxos — USDG is the venue's entire settlement layer; pari-mutuel means the house takes no risk. Arbitrum — Gaming Catalyst thesis, and a clean answer to "does it need to be on-chain." Uniswap v4 — the track itself.

**Build:** 10 days. Hardest part: half the budget goes to the front end, because the track IS the product. Keep the contract to four small pieces.

**Honest weak spot:** CoinRace already runs an 8-coin, 3-minute, price-driven race with pooled payouts. Name it first, on stage: "CoinRace is a casino with house chips on centralized feeds. We settle from real Arbitrum liquidity, pay real USDG with no custodian, and our field puts tokenized equities in the same race as memecoins — which nothing else does." Prior art you name yourself becomes validation.

**Closest existing thing:** CoinRace (live, off-chain feeds, play chips). Zed Run (simulated horses, random seed). HackMoney 2021's "Horse Race." OpenTote (real parimutuel, real horses).

---

### 4. DIVIDEND ROYALE
**The pitch:** A no-loss lottery where the jackpot is paid by Nvidia — deposit stock tokens, keep your principal forever, and the dividends everyone ignores get swept into one USDG prize.

**What you build:**
- Vault holding stock tokens, principal withdrawable 1:1 always. One stated invariant: total withdrawable principal never decreases.
- Multiplier tracker: sweep only realized `uiMultiplier` growth that has survived a 24-48h settlement delay, so a retracted corporate action can never be paid out. Fuzz-test that invariant — it's the whole ballgame.
- Sweep → swap to USDG through v4 → prize pot. Draw per epoch (operator-configurable length, not a hardcoded week) with odds proportional to time-weighted deposit. Commit-reveal randomness by default.
- Event feed UI: corporate actions as the game calendar. Split = bonus round. Dividend = the pot filling in public.

**The demo moment:** Fork mainnet at a block just before a real dividend-driven multiplier increase. Pot at zero. Advance one block — multiplier ticks, sweep fires, pot fills, draw runs, someone wins. Thirty seconds, from a corporate action that actually happened. Encore: replay the WEEK 2:1-then-retracted split and watch the vault roll the sweep back instead of paying phantom yield. That fifteen seconds is your entire smart-contract-quality score.

**Why it fits:** Robinhood Chain — ERC-8056 multipliers exist essentially only here, and you've measured them. Paxos — USDG as the prize rail. Uniswap v4 — the swap route. Judging — this is the exact shape all three NYC winners had: narrow, shipped, RWA-flavored, obvious grant continuation.

**Build:** 7 days. Hardest part: the accounting invariant under a multiplier that moves both directions — which is the same class of problem your existing test suite already covers.

**Honest weak spot:** Equity dividend yield is 1-2%/yr, so at hackathon TVL the organic pot is thin. Answer: seed season one with a labeled team/sponsor USDG bootstrap, show the label on screen, and say it out loud. Judges score that transparency up, not down.

**Closest existing thing:** PoolTogether V5 — and pitch it as exactly that: PoolTogether with a new yield adapter. The RWA gacha lane on this chain is already taken (Broker Box, Index World Assets, Gifted Stock), which is why this goes after the yield instead of the pack. Nothing found anywhere turns RWA dividend yield into a prize pool.

---

### 5. RIPCORD
**The pitch:** Five-dollar packs of real stock with a memecoin wildcard, and the growth loop is that you text them to friends who don't have a wallet.

**What you build:**
- Mint contract: pay USDG, the contract buys the basket from live v4 pools inside the mint transaction, you receive actual tokens. Zero inventory risk, EV enforced arithmetically. Price strictly from Chainlink — never apply `uiMultiplier` yourself, Robinhood's docs are explicit that the feed already includes it.
- MVP basket is 2 slots: SPY common + a random top-volume memecoin degen slot. Add NVDA/GOOGL/SPCX tiers only if the core loop is done.
- Instant buyback at ~95% back through the same pools — a plain sell call, not a separate guaranteed-price mechanism.
- Gift-claim flow: buy a pack for someone, send a link, ERC-4337 mints them a smart account on claim and the paymaster covers gas. Their first on-chain action is opening a pack and owning NVDA.

**The demo moment:** Take a judge's phone. Text them a link. No app, no wallet, no seed phrase, no gas — pack opens, animation runs, they own $3.20 of NVDA and $1.40 of ROBOCLAW. They tap sell, USDG back in one block. Thirty seconds, mainnet, a stranger's phone.

**Why it fits:** Paxos — USDG in, USDG out, and it's the first thing a brand-new AA wallet ever holds. Robinhood Chain — stock tokens as prize, v4 for atomic basket construction, AA + paymaster for the claim flow that nobody else is using. Arbitrum — the consumer lane, wide open here. Judging — PMF answers itself: on-chain gacha did $324.6M in June 2026 alone.

**Build:** 10 days. Hardest part: this stacks four subsystems (randomness, atomic basket buy, AA claim, buyback) and all four have to work live. Sequence the unknowns first — day 1 confirm a 4337 bundler/paymaster actually works end-to-end on 4663 with a trivial mint; that's a higher blast radius than VRF. Build the pack-open animation in days 3-6 against mocked outcomes so it's never the thing cut on day 12.

**Honest weak spot:** Gifted Stock on Base already does mystery boxes paying tokenized-stock slices. Answer, by name: "Gifted Stock averages 75% of box cost, no memecoin dimension, no gift-claim onboarding. Ours is positive-EV minus a stated fee, and the gift link is the product."

**Closest existing thing:** Gifted Stock (Base). Collector Crypt on Solana, $1B+ cumulative, is the category proof but it's Pokémon cards. Broker Box is already doing stock-token packs on this chain — worth a look before you commit.

---

### 6. FRACTURE
**The pitch:** The router that can actually price the 94% of tokenized-equity pools everyone else's router silently skips — because it simulates the hook, on-chain, with the search loop in Rust.

**What you build:**
- `quoteTrue(pair, amount)` as a free staticcall: pre-filter candidate pools from state, then run v4 Quoter-style revert-simulations on 3-5 of them to get the TRUE post-hook output including whatever dynamic fee, snipe tax or revert the hook applies. Returns a split plan. This is the primary artifact and every other dApp on the chain can call it for nothing.
- Executor: a separate call that replays the chosen split atomically with one minimum-output floor. Simulation gas and hostile-hook griefing never touch the paying transaction.
- The optimizer and fixed-point math (mulDiv, sqrt price math, marginal-output search) in Stylus — the single best-evidenced Stylus win there is (Orbital AMM's Q96.48 layer; 2.8x-10.6x on mulDiv).
- Build the Solidity executor and Solidity optimizer FIRST, days 1-6, working end to end. Port to Stylus days 7-10 behind a flag with Solidity as a live fallback.

**The demo moment:** Same NVDA→USDG trade, two routers, live on mainnet, both printing realized output. You win by N bps — then show WHY: a table of the pools you simulated, with "quoted from state" beside "actually returned after the hook ran," and two rows where they disagree badly. One pool charged 2.9% instead of the 0.30% its state implied. One reverted. "Nobody else's router can see this column, because getting it requires running the hook."

**Why it fits:** Arbitrum Stylus — a genuinely compute-bound inner loop, with a gas report slide as the proof. Uniswap v4 — unlock/callback internals, revert simulation, atomic execution; highest possible contract-quality read. Robinhood Chain — F5 is your own measurement, not an assertion. Paxos — USDG is the quote leg and route quality is denominated in USDG saved. Grants — a hook-aware quoter is infrastructure every launchpad and wallet on this chain needs.

**Build:** 11 days with the Solidity-first path. Hardest part: Stylus is unproven for you and there's a 24KB compressed WASM ceiling — which is exactly why Rust is days 7-10 and never on the critical path.

**Honest weak spot:** Splitshot is already live on this chain doing split routing. Say it first and state the difference precisely: Splitshot splits across venues and fee tiers using off-chain simulation of pool state; FRACTURE splits across hooked v4 pools using on-chain execution of the hook.

**Closest existing thing:** Splitshot (live here). Uniswap's own v4 Quoter (single path, off-chain use). 1inch/Odos/Kyber (off-chain solvers, not on this chain). Uniswap has published an on-chain router repo — mention it as prior art you're extending at Robinhood-Chain fragmentation scale, don't claim to be first.

---

## My pick and why

**Build BLUE CHIP.** For your team specifically, three things decide it. First, you already own most of it: the v4 execution engine, balance-delta accounting, atomic rollback and ERC-8056-aware pricing are the hook's guts, and with 13 days a running head start on the hardest contract is worth more than any idea's cleverness. Second, it scores hardest on the criterion that's listed first — smart contract quality — while still being the most repeatable sentence in the whole slate; "ape the dog coin, win the company" is a thing a judge re-tells to a colleague the next day, which is the actual memorability bar. Third, it gives your product teammate a real surface to design (the House page, the pot in shares, the hall of fame) without putting them on the critical path of the contract. And it keeps growing after October: the hook is distributable to launchpads, and the no-loss "house treasury" variant is DIVIDEND ROYALE bolted on as v2, so you don't have to choose between them forever. If after two days the pool-ownership thing genuinely sours you, switch to STOCK OR SLOP — it's a day shorter, it's the funniest thing here, and its contract surface is small enough that you cannot fail to finish it.

## What first-place projects actually have

You asked who's going to take first and what they have that you don't. Here's the honest answer, from the sister event that already ran this exact program in NYC.

The winners were Tilt Protocol, Fangorn and EqualFi. None of them invented anything. Tilt is a management layer for tokenized RWAs. EqualFi is index tokens — bundle assets into a fixed basket, no rebalancing, no governance. That's it. EqualFi's whole differentiator was that they had nine index tokens actually deployed on Robinhood Chain testnet during the hackathon window. Deployed. Not designed.

Across every hackathon winner anyone could pin down — Paybot, Rivals, Tilt, EqualFi, Hoot! — not one is a new cryptographic or economic primitive. Known thing, one sharp twist, executed tightly, beats new primitive by something like 4 to 1. The people who do ship genuine new primitives (Orbital AMM's high-dimensional concentrated liquidity) are teams who'd already spent a year on that exact math, not people who improvised it in 13 days.

What separates them, concretely, from a judge who spent a year scoring these:

- **A working end-to-end demo beats a better idea shown as slides, almost every time.** The literal instruction is: cut scope until something runs end to end.
- **Open with identity, not backstory.** "This is a tool that does X for Y." Teams that opened with context scored lower. Judges need an anchor before they can absorb anything.
- **Narrow scope reads as judgment, not timidity.** A team that built one narrow thing well reads as a team that made decisions. A team trying to build a platform reads as a team that couldn't choose.
- **Naming what breaks first raises your score.** Judges ask "what fails at scale?" and the teams who answered honestly scored higher than the ones who deflected. This is why every idea above has the weak spot written into the pitch.
- **Polish, stack choice and pedigree barely move the needle.** What moves it is whether a judge can re-explain your project to a colleague afterwards.

So: not genius. Not a secret idea nobody thought of. A one-line identity, a thing that actually runs on mainnet, a named user, a demo video where something real happens, and one sentence admitting what's broken. You have a dev who produced an adversarially-reviewed 42-test codebase in a day and measurements of this chain that nobody else in that gallery has. That is already more than most of the field brings.

Pick one today. Deploy something — anything — to mainnet by day three, even if it's a stub. Everything after that is polish and narrative, and polish and narrative is what wins.