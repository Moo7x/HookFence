# Jayo's public testnet site — build, checks, deploy, operate

**Status (2026-09-25):** **live at <https://jayo-testnet.pages.dev>**, built by
Cloudflare Pages from `master`. It now runs on **JayoBasket version 2**: anyone can
add money to a basket, it is bought by that basket's own plan, and every basket
has its own page (`?basket=101`). Version-1 baskets (#1 to #7) stay listed,
withdrawable and transferable. Why version 2 exists is in
[PRODUCT_DIRECTION.md](PRODUCT_DIRECTION.md), and the redesign is in
[design/README.md](design/README.md).

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

## Version 2 on the live testnet (2026-09-25)

Deployed beside version 1 (`contracts/script/DeployJayoV2Testnet.s.sol`), reusing
the live gateway, policy and adapter. All 15 deployment transactions succeeded.

| Contract | Address |
|---|---|
| JayoBasket v2 (ids from 101) | `0x1F0AB726154DCc487fE1Ccaf5e3ACC389226Ac0B` |
| Renderer (what wallets show) | `0x8Bca8B14F3F84684e281143BDFaa022384F1fa98` |
| TSLA / AMZN / rUSDG feeds (v2) | `0xC1CF…7C44`, `0xb28c…9B57`, `0x1c7B…3d6A` |
| Dedicated updater key | `0x4C4fF2369690CD0D5177cFFC8B46b1744C25BDE0` |
| JayoBasket v1 (still live) | `0xff5c76EAc645cb07317c95215B382909b9A00218` |

The journey ran through the rebuilt page, with two ordinary wallets:

| Step | Who | Receipt | Result |
|---|---|---|---|
| create #101, 20 rUSDG, 60/40 | Alice | `0x29a22237…24a1` | 0.041298 TSLA + 0.032988 AMZN; 998,590 gas |
| **add 8 rUSDG to Alice's #101** | Bob | `0x9bd8b3e7…d6e0` | same token grew by 0.016391 TSLA + 0.013055 AMZN; 665,905 gas |
| hand #101 to Bob | Alice | `0xcdba6124…c4b2` | 65,162 gas |
| Alice tries to withdraw or re-plan #101 | Alice | simulated | refused: `NotPositionOwner(101, Alice)` for redeemAsset, redeem and setAllocation; the page shows her no such controls and says who the owner is |
| start #102 from #101's plan, own 10 rUSDG | Alice | `0xec1a5793…d926` | #101 untouched; #102's history says where its plan came from |
| take only the AMZN out of #101 | Bob | `0xad2b56e6…520c` | 0.046043 AMZN to Bob; #101 kept with its TSLA |
| change #101's plan to 100% TSLA | Bob | `0xc5111b1b…561f` | plan version 2; nothing bought or sold |
| publish prices with the updater key | updater | `0xe531b285…804f`, `0x335d1dda…36e5`, `0xe0071bca…6926` | the owner key was not used |

`tokenURI(101)` now returns the holdings, the plan, 2 purchases, 28 rUSDG funded,
and a link to `https://jayo-testnet.pages.dev/?basket=101`
(`docs/design/after/wallet-basket-101.png` is its image).

## Keeping prices fresh while nobody's computer is on

Buying and adding money need a reference price less than an hour old.
Withdrawing, handing on and changing a plan never do.

- **Scheduled keeper** (`keeper/`): a Cloudflare Worker with a cron trigger
  every 20 minutes. It reads both pools, applies the feeds' own bounds, and
  publishes only what the feeds would accept. It has no public URL. Its one
  secret is the **updater key**, which can do nothing on chain except
  `setAnswer` on the three version-2 feeds.
- **The feeds bound that key:** at most one update per 15 minutes, no step over
  10%, and no more than 25% of movement from the start of any 24-hour window.
  A stolen updater key can therefore walk a reference price at most 25% in a
  day, one visible event at a time, until the owner calls `setUpdater`. The
  deployer (owner) key never leaves this machine.
- **Tested:** `keeper/src/decide.test.mjs` checks the rules (6/6), and
  `contracts/test/unit/DemoPriceFeed.t.sol` checks the same bounds on-chain
  (19/19). The Worker was run in Cloudflare's local runtime
  (`wrangler dev --test-scheduled`) without a key: it reports its decisions and
  sends nothing.
- **Deploying it** needs the Cloudflare account owner: `wrangler login`, then
  `npx wrangler deploy --config ../keeper/wrangler.toml` from `tools/`, then
  `./scripts/put-updater-secret.sh`. The last step pipes the key from
  `contracts/.env` into `wrangler secret put` without printing it.

Until the Worker is deployed, or if it stops, the feeds expire an hour after
their last update. Buying then pauses, the site says so, and taking tokens out
keeps working. The same refresh can be run by hand from this machine:

```bash
./scripts/keep-testnet-feeds-fresh.sh --once   # or without --once: every 20 min until Ctrl-C
node keeper/src/cli.mjs                        # what the keeper would do now, sending nothing
```

If a refresh prints `SKIPPED <asset>`, the pool moved further than a bound
allows. Look before overriding:

```bash
node scripts/find-routes.mjs testnet TSLA AMZN       # current pool prices
# if the move is genuine (e.g. steady trading by other addresses, not one block):
cd contracts && FORCE_ASSET=AMZN forge script script/ForceTestnetFeed.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast   # owner key; resets the 24-hour band
```

This happened on 2026-09-25: an unrelated address had bought both pools for
hours, AMZN had moved 12.29%, the refresh skipped it, and it was forced after
checking (`0x4ce0a9be…2500`).

## Honest limits

- The price feeds copy the pools. They cannot tell whether a pool is fairly priced.
  Today the testnet TSLA pool is about 25% below Chainlink's mainnet TSLA price.
  An "independent" testnet feed does not exist: Chainlink lists none for this
  testnet. Copying mainnet prices here would set floors far below what the pools
  pay, so it would protect nothing.
- Anyone can add money to a basket: that is the point. An addition cannot take
  anything out, but a basket's history will show additions its owner did not ask
  for.
- Creating a basket costs about 18% more gas in version 2 (998,590 against
  848,716), for the plan version and funding totals it records.
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

**If a push to `master` does not deploy:** check for Cloudflare's banner "This
project is disconnected from your Git account". It means the Cloudflare Workers
and Pages GitHub app has lost access to the repository. To fix it, open
<https://github.com/settings/installations>, go to Cloudflare Workers and Pages,
choose Configure, and check that the app is not suspended and that
`Moo7x/HookFence` is under Repository access. If that doesn't clear the banner,
uninstall the app and reinstall it via Connect to Git. Cloudflare does not build
pushes it missed while disconnected, so push again afterwards. This happened on
2026-09-25, and the first fix cleared it.
