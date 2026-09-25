# Jayo's public testnet site — build, checks, deploy, operate

**Status (2026-09-25):** **live at <https://jayo-testnet.pages.dev>**, built by
Cloudflare Pages from `master`. Headers and blocked paths were checked on the live
URL, and the owner ran a purchase and a withdrawal with their own browser wallet
(below).

## What the site is

Plain static files. No server code, no Pages Functions, no keys, no signer. Every
transaction is signed in the visitor's own browser wallet. The page reads
Robinhood Chain testnet through the public RPC.

```bash
node scripts/build-site.mjs      # -> site/dist
```

| File | What it is |
|---|---|
| `index.html` | the page, with the local-demo blocks removed |
| `app/app.js` | the app, with the local-demo blocks removed |
| `app/styles.css` | styles |
| `app/vendor/viem.js` | viem 2.21.55 bundled **without** key or account handling (`app/vendor/viem-hosted.js`, reproducible via `node tools/build-vendor.mjs --check`) |
| `deployment.json` | public addresses only, from `deployments/robinhood-testnet.json` |
| `_headers` | Cloudflare response headers |
| `404.html` | returned for every other path (no fallback to the app) |

## What the build refuses to ship

`scripts/build-site.mjs` scans its own output and fails on: a leftover local-only
block; the local test signer or its token; `localhost` / `127.0.0.1`; anvil or any
key-to-account constructor; any 64-hex value in the page, app or manifest; any
known key (anvil's published ones and, on a machine that has it, the three in
`contracts/.env`) anywhere including the vendored bundle; an unexpected file; a
manifest field outside the public schema, the wrong chain, the wrong RPC, or demo
controls switched on. `node --test scripts/build-site.test.mjs` plants each of
these into a copy of the sources and requires a refusal (10/10).

## Response headers

```
Content-Security-Policy: default-src 'none'; script-src 'self';
  style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com;
  img-src 'self' data:; connect-src 'self' https://rpc.testnet.chain.robinhood.com;
  frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; upgrade-insecure-requests
X-Content-Type-Options: nosniff        X-Frame-Options: DENY        Referrer-Policy: no-referrer
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), hid=(), bluetooth=()
Cross-Origin-Opener-Policy: same-origin    Cross-Origin-Resource-Policy: same-origin
Strict-Transport-Security: max-age=31536000
```

Scripts come only from the site itself. The page can connect only to itself and
the testnet RPC. Styles allow inline `style=` attributes (the markup uses them)
and Google Fonts' stylesheet; fonts come from Google's font host. That is the
only third-party origin, and it serves no script.

## How it was verified

| Check | Result |
|---|---|
| `wrangler pages dev site/dist` (Cloudflare's own runtime) | every header present as above; `/_headers`, `/.env`, `/.git/config`, `/contracts/.env` → 404 page, not the app |
| Page under that runtime | loads, clean console, fonts load under the CSP, read-only view without a wallet |
| Read-only view | prices with age, "Buying is unavailable" when expired, baskets listed, connect prompts |
| Phone width (375 px) | no horizontal overflow, 44 px touch targets |
| Wallet journey, hosted build | see below |

The wallet journey was run against the **built** site served with its own
`_headers` (`node scripts/serve-site.mjs --test-wallet`). Because the browser
used for verification has no wallet extension, that mode injects a small
EIP-1193 provider — visibly labelled "LOCAL VERIFICATION ONLY" — backed by the
local test signer (Alice's and Bob's keys only, decoded allowlist). It exists
only in that server's responses; `site/dist` does not contain it, and the build
refuses to. Everything the app does goes through the same `window.ethereum`
interface a real wallet provides.

| Who | What, on the hosted build | Receipt |
|---|---|---|
| Bob | withdraw basket #1 **while every price had expired** | `0xd89ded62…12e4` |
| Alice | mint 100 test rUSDG from the "Get set up" step | `0xc4dcb560…ce8a` |
| Alice | create basket #4 (20 rUSDG) | `0x13b91bd3…6a7d` |
| Alice | hand #4 to Bob (address typed, reviewed, confirmed) | `0xe6afd9d0…6f17` |
| Bob | take only the AMZN out of #4 | `0x0097532e…79ce` |

All in `docs/evidence/testnet-2026-09-24.json`.

**With a real wallet on the live site (2026-09-25).** The owner used a browser
wallet extension on <https://jayo-testnet.pages.dev>, from a fresh address
`0xEDC63393bf4eBd5310E5260121D2b474fCb86a7a`:

| What | Receipt | Result |
|---|---|---|
| mint 100 test rUSDG | `0x8e57621a…2687` | success |
| approve the basket contract | `0x8599c266…f629` | success, but see below |
| create basket #5 with 20 rUSDG (60% TSLA / 40% AMZN) | `0x95b8776d…1b93` | 0.042470 TSLA + 0.034286 AMZN bought, all 20 spent |
| withdraw 25% of #5 | `0xd9ead6ef…8fbb` | 0.010618 TSLA + 0.008572 AMZN sent to the wallet |

The one problem it found: the page asked the wallet for an allowance of one
billion rUSDG rather than the purchase amount. Because `JayoBasket` only ever
pulls from `msg.sender`, nobody else could have used that allowance. Still, it
is the kind of request a wallet flags, and it is not needed. The page now
approves exactly the amount being spent.

One known risk to watch for with other wallets: a wallet that injects its provider with an
*inline* script would be blocked by `script-src 'self'`. Current MetaMask and Rabby
inject from the extension, which a page's CSP does not govern.

## Running a supervised demo session

Buying works only while the price feeds are fresh (one hour each). Outside a
session they expire, buying is paused with an explanation, and withdrawals keep
working.

```bash
./scripts/keep-testnet-feeds-fresh.sh          # at the start; repeats every 40 min
# Ctrl-C at the end. Feeds expire an hour later; buying pauses by itself.
```

If a refresh prints `SKIPPED <asset>`, the pool moved more than 10% since the last
publish. Look before overriding:

```bash
node scripts/find-routes.mjs testnet TSLA AMZN       # current pool prices
# if the move is genuine (e.g. steady trading by other addresses, not one block):
cd contracts && FORCE_ASSET=AMZN forge script script/ForceTestnetFeed.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
```

This happened on 2026-09-25: an unrelated address had bought both pools for
hours, AMZN had moved 12.29%, the refresh skipped it, and it was forced after
checking (`0x4ce0a9be…2500`).

## Honest limits

- The price feeds copy the pools. They cannot tell whether a pool is fairly priced.
- The pools are tiny (about 2,000 rUSDG for TSLA, 900 for AMZN) and other testnet
  users trade them; each purchase moves the price for the next buyer.
- Test assets have no value. rUSDG is a public test token anyone can mint; it is
  not Paxos USDG and not Jayo's.

## Publishing: Cloudflare Pages Git integration

Cloudflare builds the site from GitHub on every push. `master` is the production
branch and deploys to `https://jayo-testnet.pages.dev`. Other branches get
preview URLs.

| Setting | Value |
|---|---|
| Production branch | `master` |
| Framework preset | None |
| Build command | `node scripts/build-site.mjs` |
| Build output directory | `site/dist` (also set in `wrangler.toml`) |
| Node version | from `.node-version` (22) |
| Environment variables | none; the build needs no secrets |

The build uses only Node's built-in modules and needs no `npm install`. It was
checked from a clean clone with no `contracts/.env` and no `tools/node_modules`:
the output matched the verified local build apart from line endings.
