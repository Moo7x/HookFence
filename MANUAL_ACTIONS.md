# Manual actions — things a person must do

> **Current status (2026-09-24):** one item blocks the public testnet
> deployment: item 1 below, a faucet drip of at least **0.001 ETH** into the
> dedicated testnet wallet. The earlier figure (0.0003 ETH) was wrong: it came from
> a local simulation that cannot see Robinhood Chain's L1 data fee and that priced
> calls into freshly deployed contracts as empty calls. The corrected figure is
> derived in `scripts/estimate-testnet-cost.mjs` from real receipts.


Only items that genuinely cannot be automated from this session appear here.
Everything else is done in the repo. Each entry says *why* a human is needed,
*where*, what the safe input/output is, and how completion gets verified.

**Never paste a private key or seed phrase into a chat window.** Use
`contracts/.env` (git-ignored) or a `cast wallet` keystore. `.env.example` shows
the shape; `.gitignore` already excludes `.env`.

---

## Open

### 1. Fund a dedicated testnet wallet — BLOCKING for testnet deployment

**Why a person:** every faucet is behind a browser flow with a captcha or a
social login. Automated captcha solving is out of scope and not something I will
do.

**How much:** **at least 0.001 ETH.** Derivation, from receipts of the whole
sequence replayed on a fork of the testnet, plus each transaction's L1 data fee
read from the chain's NodeInterface (`scripts/estimate-testnet-cost.mjs`):

| | transactions | ETH at 0.01 gwei |
|---|---:|---:|
| deployment | 19 | 0.0001269 |
| one full journey (approve, create, copy, two partial exits, hand-over, close) | 7 | 0.0000227 |
| one feed refresh | 3 | 0.0000013 |
| plan: 1 deployment + 5 journeys + 30 refreshes | | 0.0002808 |
| with 3x headroom for fee spikes | | **0.0008423** |

0.001 ETH covers that with room to spare. Most faucets give more.

**Where** — all three were reachable on 2026-09-23, use whichever works:

| Faucet | Checked |
|---|---|
| <https://faucet.testnet.chain.robinhood.com/> | reachable, rate-limited (HTTP 429) |
| <https://faucet.quicknode.com/robinhood/testnet> | HTTP 200 |
| <https://faucets.chain.link/robinhood-testnet> | HTTP 200 |

**Input:** the address of a **dedicated throwaway testnet wallet**. Generate one
with:

```bash
./scripts/new-testnet-wallet.sh
```

That prints an address and writes the key to `contracts/.env` only, which is
git-ignored. Never paste a private key into a chat window.

**Expected output:** testnet ETH on Robinhood Chain Testnet (chain 46630).

**How I verify:** I query the balance directly and will confirm the exact figure:

```bash
cast balance <ADDRESS> --rpc-url https://rpc.testnet.chain.robinhood.com
```

**What you do NOT need to do:**

- No token faucet. `mint(address,uint256)` on testnet rUSDG
  (`0x7C902600cb5bf24225DF1a77b333D84e03C1F210`) is open to any caller, and the
  deploy script mints the demo wallet 10,000 rUSDG itself.
- No RPC key, explorer key or allowlist. The public endpoint works unauthenticated.
- No liquidity to provide. The TSLA/rUSDG and AMZN/rUSDG pools already exist,
  already hold other people's liquidity, and carry no hook.

---

### 2. Confirm the submission deadline timezone in the logged-in dashboard

**Why a person:** requires a HackQuest login.

**Where:** HackQuest → the buildathon page → Schedule, while signed in.

**What I already established without logging in** (see
`docs/HACKATHON_REQUIREMENTS.md` §4): the public page renders schedule times in
the *viewer's local* timezone. I proved this by reconciling the live countdown
(`12D 10H 53M` at `2026-09-20 14:08:34 GMT+0800`) against the displayed
registration end (`Oct 3, 2026 01:01`) — they match exactly.

Therefore:

> **Submission closes 2026-10-04 15:59 UTC** (= 23:59 Singapore time).

**What to confirm:** that the dashboard agrees. If it shows something else, tell
me and I will update the requirements doc.

---

### 3. Register the team and submit the project

**Why a person:** account-bound action behind a login. I will not submit on
anyone's behalf.

**Where:** HackQuest → Submit Project.

**The form fields** (as you provided them) and who fills each:

| Field | Limit | Status |
|---|---|---|
| Select the Project to Submit | — | you (needs a HackQuest project record) |
| What is your contract address? | — | I supply after deployment |
| Prize tracks (multi-select) | — | **suggest: Overall + Promising Products + Grants** |
| Link to frontend/UI/website | 300 | I supply |
| Core Protocol / Smart Contract Addresses | 300 | I supply |
| Factory/Pool Contracts (if applicable) | 300 | I supply |
| Token Contract Address (if applicable) | 300 | I supply |
| Which parts of your code were produced during the Buildathon? | 300 | I supply |

All four free-text fields are capped at **300 characters**. I will write them to
that limit verbatim in `docs/SUBMISSION_COPY.md` so they can be pasted directly.

---

### 4. Record and upload the demo video

**Why a person:** screen recording and publishing to an account.

**Where:** your own recorder; upload to YouTube/Loom (unlisted is fine).

**Input:** `docs/DEMO_SCRIPT.md` — a shot-by-shot two-minute script with the exact
commands to run and what each screen should show.

**How I verify:** I cannot verify the upload. Paste the link back and I will put
it in the submission copy.

---

### 5. Team names, bios and social links

**Why a person:** I do not know them and will not invent them.

**Input needed:** display name(s), one-line bio each, GitHub/X links.

---

## Not required (resolved without a human)

- ~~Robinhood Chain RPC access~~ — public endpoints work with no API key:
  `https://rpc.mainnet.chain.robinhood.com`, `https://rpc.testnet.chain.robinhood.com`.
  Verified reachable: mainnet chainId 4663, testnet chainId 46630.
- ~~Chainlink feed addresses~~ — read from the public reference-data directory.
  AAPL/USD `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`, USDG/USD
  `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`, both 8 decimals, 86400s heartbeat.
- ~~Chainlink Data Streams credentials~~ — **not needed.** Standard push feeds
  cover this product. Data Streams stay out of scope; see `docs/THREAT_MODEL.md`.
- ~~Uniswap v4 addresses~~ — published; PoolManager on Robinhood Chain mainnet is
  `0x8366a39cc670b4001a1121b8f6a443a643e40951`. See `docs/DEPLOYMENTS.md`.
- ~~Hackathon rules and judging criteria~~ — read from the live public page and
  recorded with the access date in `docs/HACKATHON_REQUIREMENTS.md`.
