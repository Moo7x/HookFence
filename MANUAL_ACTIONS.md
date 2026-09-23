# Manual actions — things a person must do

> **Current status (2026-09-22):** nothing is blocking development. Milestone 1
> is complete and runs locally with mock assets. Item 1 below becomes blocking
> only when we deploy to testnet, which is step 3 of the next phase.


Only items that genuinely cannot be automated from this session appear here.
Everything else is done in the repo. Each entry says *why* a human is needed,
*where*, what the safe input/output is, and how completion gets verified.

**Never paste a private key or seed phrase into a chat window.** Use
`contracts/.env` (git-ignored) or a `cast wallet` keystore. `.env.example` shows
the shape; `.gitignore` already excludes `.env`.

---

## Open

### 1. Fund a dedicated testnet wallet — BLOCKING for testnet deployment

**Why a person:** the faucet is behind a browser flow and likely a captcha or
social login. Automated captcha solving is out of scope and not something I will
do.

**Where:** <https://faucet.testnet.chain.robinhood.com/>

**Input:** the address of a **dedicated throwaway testnet wallet**. Generate one
with:

```bash
cd contracts && ../scripts/new-testnet-wallet.sh
```

That prints an address and writes the key to `contracts/.env` only.

**Expected output:** a small amount of testnet ETH on Robinhood Chain Testnet
(chain ID 46630). Native gas token is ETH.

**How I verify:** I query the balance directly and will confirm the exact figure:

```bash
cast balance <ADDRESS> --rpc-url https://rpc.testnet.chain.robinhood.com
```

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
