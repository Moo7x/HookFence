// =============================================================================
// Jayo demo interface
//
// Design goals, in priority order:
//   1. Someone who has never used a blockchain can complete the journey.
//   2. Every rejection says, in plain words, what happened and what to change.
//      The contract's own error name and raw units stay available, but folded
//      away in technical details rather than shown as the primary message.
//   3. Transaction state is always explicit: idle, signing, pending, confirmed
//      or failed. Never a button that silently does nothing.
//
// Everything here runs against a LOCAL chain with MOCK assets.
// =============================================================================

// viem 2.21.55, bundled locally by tools/build-vendor.mjs. The page used to load
// it from esm.sh at runtime, which put third-party code in the same page as the
// test signer's token. It now loads nothing from any other origin.
import {
  createPublicClient, createWalletClient, http, custom, parseUnits, formatUnits,
  isAddress, getAddress, privateKeyToAccount, foundry,
} from '/app/vendor/viem.js';

// Anvil's deterministic accounts. These keys are published in Foundry's own
// documentation and hold nothing on any real network. A local demo that required
// a wallet extension would not survive a recorded walkthrough.
//
// They are used ONLY when the deployment report says chainId 31337. On any
// public chain the app signs through an injected wallet instead and these are
// never touched - see `connect()`.
const LOCAL_ACCOUNTS = [
  { label: 'Wallet A', key: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' },
  { label: 'Wallet B', key: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' },
];

let ACCOUNTS = LOCAL_ACCOUNTS;
let acctIndex = 0;
let isLocal = true;
let chain = foundry;
let injected = null; // viem wallet client backed by window.ethereum

const account = () => (isLocal ? privateKeyToAccount(ACCOUNTS[acctIndex].key) : { address: injectedAddress });
let injectedAddress = null;
let signerLabel = 'browser wallet';

let pub = createPublicClient({ chain: foundry, transport: http('http://127.0.0.1:8545') });
const wallet = () => (isLocal
  ? createWalletClient({ account: privateKeyToAccount(ACCOUNTS[acctIndex].key), chain, transport: http(chain.rpcUrls.default.http[0]) })
  : injected);

// ---------------------------------------------------------------- ABIs ------

const BASKET_ABI = [
  { type:'function', name:'previewCreate', stateMutability:'view',
    inputs:[{name:'allocation',type:'tuple[]',components:[{name:'asset',type:'address'},{name:'weightBps',type:'uint16'}]},{name:'usdgIn',type:'uint256'}],
    outputs:[{type:'uint256[]'},{type:'uint256[]'},{type:'uint256[]'},{type:'uint256'}] },
  { type:'function', name:'create', stateMutability:'nonpayable',
    inputs:[{name:'allocation',type:'tuple[]',components:[{name:'asset',type:'address'},{name:'weightBps',type:'uint16'}]},{name:'usdgIn',type:'uint256'},{name:'deadline',type:'uint256'}],
    outputs:[{type:'uint256'}] },
  { type:'function', name:'copyAllocation', stateMutability:'nonpayable',
    inputs:[{type:'uint256'},{type:'uint256'},{type:'uint256'}], outputs:[{type:'uint256'}] },
  { type:'function', name:'holdingsOf', stateMutability:'view', inputs:[{type:'uint256'}],
    outputs:[{type:'address[]'},{type:'uint256[]'}] },
  { type:'function', name:'allocationOf', stateMutability:'view', inputs:[{type:'uint256'}],
    outputs:[{type:'tuple[]',components:[{name:'asset',type:'address'},{name:'weightBps',type:'uint16'}]}] },
  { type:'function', name:'ownerOf', stateMutability:'view', inputs:[{type:'uint256'}], outputs:[{type:'address'}] },
  { type:'function', name:'transferFrom', stateMutability:'nonpayable', inputs:[{type:'address'},{type:'address'},{type:'uint256'}], outputs:[] },
  { type:'function', name:'safeTransferFrom', stateMutability:'nonpayable', inputs:[{type:'address'},{type:'address'},{type:'uint256'}], outputs:[] },
  { type:'function', name:'positionVersion', stateMutability:'view', inputs:[{type:'uint256'}], outputs:[{type:'uint64'}] },
  { type:'function', name:'redeem', stateMutability:'nonpayable', inputs:[{type:'uint256'}], outputs:[] },
  { type:'function', name:'redeemAsset', stateMutability:'nonpayable', inputs:[{type:'uint256'},{type:'address'}], outputs:[] },
  { type:'function', name:'redeemFraction', stateMutability:'nonpayable', inputs:[{type:'uint256'},{type:'uint16'}], outputs:[] },
  { type:'function', name:'minLegInput', stateMutability:'view', inputs:[], outputs:[{type:'uint256'}] },
  // Errors — every contract in the call path, so a nested revert decodes.
  { type:'error', name:'LegBelowMinimum', inputs:[{type:'address'},{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'LegWouldAcquireNothing', inputs:[{type:'address'},{type:'uint256'}] },
  { type:'error', name:'LegAcquiredNothing', inputs:[{type:'address'},{type:'uint256'}] },
  { type:'error', name:'WeightsMustSumToBps', inputs:[{type:'uint256'}] },
  { type:'error', name:'DuplicateAsset', inputs:[{type:'address'}] },
  { type:'error', name:'AssetNotSupported', inputs:[{type:'address'}] },
  { type:'error', name:'NoLegs', inputs:[] },
  { type:'error', name:'TooManyLegs', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'NotPositionOwner', inputs:[{type:'uint256'},{type:'address'}] },
  { type:'error', name:'AssetNotHeld', inputs:[{type:'uint256'},{type:'address'}] },
  { type:'error', name:'FractionOutOfRange', inputs:[{type:'uint16'}] },
  { type:'error', name:'FractionWouldDeliverNothing', inputs:[{type:'uint256'},{type:'uint16'}] },
  { type:'error', name:'OutputBelowFloor', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'InputOverspent', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'IntentExpired', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'FeedStale', inputs:[{type:'address'},{type:'uint256'},{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'FeedAnswerNotPositive', inputs:[{type:'address'},{type:'int256'}] },
  { type:'error', name:'OraclePausedForCorporateAction', inputs:[{type:'address'}] },
  { type:'error', name:'CorporateActionPending', inputs:[{type:'address'},{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'TokenNotSupported', inputs:[{type:'address'}] },
  { type:'error', name:'ERC721InsufficientApproval', inputs:[{type:'address'},{type:'uint256'}] },
  { type:'error', name:'ERC721InvalidReceiver', inputs:[{type:'address'}] },
  { type:'error', name:'ERC721IncorrectOwner', inputs:[{type:'address'},{type:'uint256'},{type:'address'}] },
];

const ERC20_ABI = [
  { type:'function', name:'approve', stateMutability:'nonpayable', inputs:[{type:'address'},{type:'uint256'}], outputs:[{type:'bool'}] },
  { type:'function', name:'balanceOf', stateMutability:'view', inputs:[{type:'address'}], outputs:[{type:'uint256'}] },
  { type:'function', name:'allowance', stateMutability:'view', inputs:[{type:'address'},{type:'address'}], outputs:[{type:'uint256'}] },
  { type:'function', name:'symbol', stateMutability:'view', inputs:[], outputs:[{type:'string'}] },
  { type:'function', name:'name', stateMutability:'view', inputs:[], outputs:[{type:'string'}] },
  { type:'function', name:'setOraclePaused', stateMutability:'nonpayable', inputs:[{type:'bool'}], outputs:[] },
  { type:'function', name:'oraclePaused', stateMutability:'view', inputs:[], outputs:[{type:'bool'}] },
];

const FEED_ABI = [
  { type:'function', name:'setAnswer', stateMutability:'nonpayable', inputs:[{type:'int256'}], outputs:[] },
  { type:'error', name:'NotUpdater', inputs:[{type:'address'}] },
  { type:'error', name:'StepTooLarge', inputs:[{type:'int256'},{type:'int256'},{type:'uint16'}] },
  { type:'function', name:'latestRoundData', stateMutability:'view', inputs:[],
    outputs:[{type:'uint80'},{type:'int256'},{type:'uint256'},{type:'uint256'},{type:'uint80'}] },
];

// The policy is the source of truth for which feed prices which asset and how
// old it may be. Reading it here, rather than trusting the manifest, means the
// freshness panel shows exactly what a purchase will be checked against.
const POLICY_ABI = [
  { type:'function', name:'stockTokenConfig', stateMutability:'view', inputs:[{type:'address'}],
    outputs:[{type:'tuple', components:[
      {name:'feed',type:'address'},{name:'maxStaleness',type:'uint32'},{name:'maxShortfallBps',type:'uint16'},
      {name:'tokenDecimals',type:'uint8'},{name:'hasOraclePaused',type:'bool'},{name:'hasCorporateActionData',type:'bool'}]}] },
  { type:'function', name:'quoteAssetConfig', stateMutability:'view', inputs:[{type:'address'}],
    outputs:[{type:'tuple', components:[
      {name:'feed',type:'address'},{name:'maxStaleness',type:'uint32'},{name:'tokenDecimals',type:'uint8'}]}] },
];

// ------------------------------------------------------------ plain words ---

// Each entry turns a contract error into something a person can act on.
// `a` is the decoded argument list.
const PLAIN = {
  NotUpdater: a => ({
    title: `${short(a[0])} is not allowed to change prices.`,
    fix: 'Only the feed\'s owner and its named updater can. This is deliberate: an open price feed lets anyone move the price your purchase is checked against.',
  }),
  StepTooLarge: a => ({
    title: 'That price change is too large to accept in one step.',
    fix: `The feed refuses moves over ${Number(a[2]) / 100}% at once. Buying stays paused until someone checks why the price moved.`,
  }),
  // Also reached on create/copy: baskets are minted with _safeMint, so a wallet
  // that is really a smart account without an ERC-721 receiver (for example an
  // EIP-7702-delegated address, which the cost simulation ran into on testnet)
  // is refused rather than handed a position it could never move.
  ERC721InvalidReceiver: a => (String(a[0]).toLowerCase() === account().address.toLowerCase()
    ? { title: 'Your wallet cannot hold baskets.',
        fix: 'It is a smart-contract account that does not accept this kind of token (ERC-721), so the basket was not created and nothing was spent. Use an ordinary wallet address.' }
    : { title: `${short(a[0])} is a contract that cannot hold baskets.`,
        fix: "Nothing was sent. Hand it to a person's wallet address instead." }),
  ERC721IncorrectOwner: () => ({
    title: 'You no longer own this basket.',
    fix: 'It may already have been handed over. Reload to see its current owner.',
  }),
  AssetNotHeld: a => ({
    title: `This basket no longer holds any ${symOf(a[1])}.`,
    fix: 'You have already taken that one out. Pick another, or withdraw everything to close the basket.',
  }),
  FractionOutOfRange: a => ({
    title: `${Number(a[0]) / 100}% is not a share you can take out.`,
    fix: 'Choose something between a sliver and all of it.',
  }),
  FractionWouldDeliverNothing: () => ({
    title: 'That share is too small to move anything.',
    fix: 'The basket holds so little that this fraction rounds to zero. Take out a bigger share, or withdraw everything.',
  }),
  WeightsMustSumToBps: a => ({
    title: `Your allocations add up to ${(Number(a[0]) / 100).toFixed(0)}%.`,
    fix: 'They need to total exactly 100%. Adjust one of the slices.',
  }),
  LegBelowMinimum: a => ({
    title: `The ${symOf(a[0])} slice is only ${usdg(a[1])} USDG.`,
    fix: `Each slice needs at least ${usdg(a[2])} USDG. Put in more money, or give that token a bigger share.`,
  }),
  LegWouldAcquireNothing: a => ({
    title: `The ${symOf(a[0])} slice is too small to buy anything.`,
    fix: 'It would spend money and get zero tokens back, so we stopped. Increase the amount or that slice’s share.',
  }),
  LegAcquiredNothing: a => ({
    title: `The ${symOf(a[0])} purchase came back with nothing.`,
    fix: 'Nothing was spent. This usually means there is not enough liquidity for that token right now.',
  }),
  DuplicateAsset: a => ({
    title: `${symOf(a[0])} appears twice.`,
    fix: 'Each token can only have one slice. Combine them into a single row.',
  }),
  AssetNotSupported: a => ({
    title: `${symOf(a[0])} is not available in this basket.`,
    fix: 'Only tokens with a reviewed trading route can be bought. Pick a different one.',
  }),
  NoLegs: () => ({ title: 'Your basket is empty.', fix: 'Add at least one token before creating it.' }),
  TooManyLegs: a => ({ title: `${a[0]} tokens is too many.`, fix: `The most a basket can hold is ${a[1]}.` }),
  NotPositionOwner: a => ({
    title: 'This basket is not yours any more.',
    fix: 'Only the current owner can do that. If you handed it over, control went with it.',
  }),
  OutputBelowFloor: a => ({
    title: 'The price moved against you, so we stopped the purchase.',
    fix: `You would have received ${tok(a[0])}, but the fair price means you should get at least ${tok(a[1])}. Nothing was spent — your money is still in your wallet. Try a smaller amount, which moves the price less.`,
  }),
  InputOverspent: a => ({
    title: 'The purchase tried to spend more than you authorised.',
    fix: 'It was cancelled and nothing left your wallet.',
  }),
  IntentExpired: () => ({
    title: 'This took too long and the authorisation expired.',
    fix: 'Nothing was spent. Just try again.',
  }),
  FeedStale: () => ({
    title: 'We cannot get a current price right now.',
    fix: 'Buying is paused until prices update — stock prices only update while markets are open. You can still withdraw the tokens from any basket you already own.',
  }),
  FeedAnswerNotPositive: () => ({
    title: 'The price feed returned an invalid value.',
    fix: 'Buying is paused until it recovers. Withdrawing still works.',
  }),
  OraclePausedForCorporateAction: a => ({
    title: `${symOf(a[0])} is paused by its issuer.`,
    fix: 'This happens around events like dividends or share splits. Buying resumes when the issuer does. Withdrawing still works.',
  }),
  CorporateActionPending: a => ({
    title: `${symOf(a[0])} has a change taking effect shortly.`,
    fix: 'We do not trade across that moment because the price and the token can briefly disagree. Try again afterwards.',
  }),
  TokenNotSupported: a => ({ title: `${symOf(a[0])} is not a recognised token here.`, fix: 'Pick one from the list.' }),
  ERC721InsufficientApproval: () => ({
    title: 'This basket is not yours to move.',
    fix: 'Switch to the wallet that owns it.',
  }),
};

// ----------------------------------------------------------------- state ----

let D = null;                 // deployed addresses
let META = {};                // address -> {symbol, name}
let ASSETS = [];              // selectable assets
let rows = [];                // [{asset, pct}]
let selectedId = null;
let minLeg = 1_000000n;

const $ = id => document.getElementById(id);
const short = a => a ? a.slice(0, 6) + '…' + a.slice(-4) : '—';
// Force one locale. The copy is English, so a browser set to a comma-decimal
// locale would render "10 000,00 USDG" beside "at least 23,411765" - two
// different separator conventions in the same sentence, in a financial UI.
const NUM = 'en-US';
const usdg = v => Number(formatUnits(BigInt(v), 6)).toLocaleString(NUM, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const tok  = v => Number(formatUnits(BigInt(v), 18)).toLocaleString(NUM, { minimumFractionDigits: 4, maximumFractionDigits: 6 });
const symOf = a => (META[String(a).toLowerCase()]?.symbol) || short(a);

function log(msg, cls = '') {
  const el = $('log');
  const d = document.createElement('div');
  if (cls) d.className = cls;
  d.textContent = `${new Date().toLocaleTimeString()}  ${msg}`;
  el.appendChild(d);
  el.scrollTop = el.scrollHeight;
}

/** Walk a viem error chain to the decoded contract error. */
function decode(e) {
  let cur = e;
  for (let i = 0; i < 14 && cur; i++) {
    if (cur.errorName) return { name: cur.errorName, args: cur.args || [] };
    if (cur.data && cur.data.errorName) return { name: cur.data.errorName, args: cur.data.args || [] };
    cur = cur.cause;
  }
  return null;
}

/** Render a rejection: plain language first, machine detail folded away. */
function showError(target, e) {
  const dec = decode(e);
  const plain = dec && PLAIN[dec.name] ? PLAIN[dec.name](dec.args) : null;
  const raw = (e?.shortMessage || e?.message || String(e)).split('\n').slice(0, 4).join('\n');

  const title = plain ? plain.title : 'That did not go through.';
  const fix = plain ? plain.fix : 'Nothing was spent. See the technical details below.';

  const detail = dec
    ? `${dec.name}(${dec.args.map(x => String(x)).join(', ')})\n\n${raw}`
    : raw;

  $(target).innerHTML =
    `<div class="msg error"><span class="icon">!</span><div class="body">
       <strong>${esc(title)}</strong><br>${esc(fix)}
       <details class="tech"><summary>Technical details</summary><pre>${esc(detail)}</pre></details>
     </div></div>`;
  log(`${dec ? dec.name : 'error'} — ${title}`, 'err');
}

function showOk(target, title, body = '') {
  $(target).innerHTML =
    `<div class="msg success"><span class="icon">✓</span><div class="body">` +
    `<strong>${esc(title)}</strong>${body ? '<br>' + esc(body) : ''}</div></div>`;
}
function clearMsg(...ids) { ids.forEach(i => { if ($(i)) $(i).innerHTML = ''; }); }
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

/** Explicit transaction lifecycle. */
function tx(id, state, label) {
  const el = $(id);
  el.hidden = false;
  el.dataset.state = state;
  el.querySelector('.label').textContent = label;
  if (state === 'confirmed' || state === 'failed') setTimeout(() => { el.hidden = true; }, 6000);
}

function busy(btn, on, label) {
  btn.disabled = on;
  if (on) { btn.dataset.text = btn.textContent; btn.innerHTML = `<span class="spin"></span>${esc(label || 'Working…')}`; }
  else if (btn.dataset.text) { btn.textContent = btn.dataset.text; }
}

// ------------------------------------------------------------------ boot ----

/// Whichever deploy script ran last writes contracts/reports/jayo-deployment.json.
/// The server never exposes that path; it serves a copy reduced to an allowlist
/// of address, number and URL fields at this route (see app/serve.mjs).
const REPORT = '/deployment.json';

async function loadDeployment() {
  try {
    const r = await fetch(REPORT, { cache: 'no-store' });
    if (r.ok) return await r.json();
  } catch { /* fall through to the message below */ }
  return null;
}

/// On a local chain the demo drives published anvil keys directly. On any public
/// chain it must not hold a key at all, so it asks an injected wallet instead.
async function connect() {
  isLocal = D.chainId === 31337;

  chain = isLocal ? foundry : {
    id: D.chainId,
    name: D.network || `chain ${D.chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [D.rpcUrl] } },
  };
  pub = createPublicClient({ chain, transport: http(isLocal ? 'http://127.0.0.1:8545' : D.rpcUrl) });

  if (isLocal) return true;

  // A browser wallet always wins. Failing that, the local server may offer a
  // test signer (node app/serve.mjs --testnet-signer). It holds the testnet key
  // in its own process and hands the page nothing but signatures; it answers
  // only this origin, and only with the per-run token embedded in this page.
  const token = document.querySelector('meta[name="jayo-signer-token"]')?.content;
  if (!window.ethereum && Array.isArray(D.localSigners) && D.localSigners.length && token) {
    let id = 0;
    const provider = {
      async request({ method, params }) {
        const r = await fetch('/signer', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-jayo-signer-token': token },
          body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }),
        });
        const out = await r.json();
        if (out.error) throw Object.assign(new Error(out.error.message), { code: out.error.code });
        return out.result;
      },
    };
    // Two independent user wallets, so a hand-over can be followed by the
    // recipient withdrawing. The signer refuses anything outside the journey.
    const labels = ['Test wallet A', 'Test wallet B'];
    const useSigner = addr => {
      injectedAddress = addr;
      injected = createWalletClient({ account: addr, chain, transport: custom(provider) });
    };
    useSigner(D.localSigners[0]);
    signerLabel = 'local test signer';
    $('signerSel').innerHTML = D.localSigners
      .map((a, i) => `<option value="${a}">${labels[i] || 'Wallet ' + (i + 1)} ${short(a)}</option>`).join('');
    $('signerPick').hidden = false;
    $('signerSel').addEventListener('change', async () => {
      useSigner($('signerSel').value);
      hideTransferConfirm();
      $('toAddr').value = '';
      validateRecipient();
      await refreshStatus();
      await loadPositions();
      log(`now signing as ${short(injectedAddress)}`);
    });
    return true;
  }

  if (!window.ethereum) {
    $('netmeta').textContent = `${D.network} — no browser wallet found`;
    $('createMsg').innerHTML =
      `<div class="msg warn"><span class="icon">!</span><div class="body">` +
      `<strong>This deployment is on a public network, so it needs a browser wallet.</strong><br>` +
      `Install one and reload. The built-in demo keys are only ever used on a local test chain, never here.</div></div>`;
    return false;
  }
  const [addr] = await window.ethereum.request({ method: 'eth_requestAccounts' });
  injectedAddress = addr;
  injected = createWalletClient({ account: addr, chain, transport: custom(window.ethereum) });

  const current = await window.ethereum.request({ method: 'eth_chainId' });
  if (parseInt(current, 16) !== D.chainId) {
    try {
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [{
          chainId: '0x' + D.chainId.toString(16),
          chainName: D.network,
          nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: [D.rpcUrl],
          blockExplorerUrls: D.explorer ? [D.explorer] : undefined,
        }],
      });
    } catch { /* the wallet may already know it, or the user declined */ }
  }
  return true;
}

async function boot() {
  D = await loadDeployment();
  if (!D) {
    $('netmeta').textContent = 'no deployment found — run ./scripts/run-demo.sh';
    log('no deployment report found. Run a deploy script.', 'err');
    return;
  }

  if (!(await connect())) return;

  // Demo controls need anvil (time travel) and ownership of the feeds. Neither
  // is available on a public chain, so the panel goes rather than sitting there
  // pretending.
  if (D.demoControls === false) {
    document.querySelector('.demo').hidden = true;
  }

  // On the local chain every asset is a mock. On testnet the tokens, the pools
  // and the PoolManager are real and only the price feeds are ours. Saying
  // "mock assets" there would be wrong in the other direction.
  document.querySelector('.mockflag').textContent =
    isLocal ? 'Demo · mock assets' : 'Testnet · mock price feeds';

  const stocks = D.stocks || [D.aapl, D.nvda].filter(Boolean);
  for (const a of [...stocks, D.usdg]) {
    const [symbol, name] = await Promise.all([
      pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'symbol' }),
      pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'name' }),
    ]);
    META[a.toLowerCase()] = { symbol, name: name.replace(' [MOCK]', '') };
  }
  ASSETS = stocks;
  minLeg = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'minLegInput' });

  rows = stocks.map((asset, i) => ({ asset, pct: i === 0 ? 60 : 40 }));
  renderRows();

  if (D.suggestedFund) {
    $('fund').value = formatUnits(BigInt(D.suggestedFund), 6);
    $('copyFund').value = formatUnits(BigInt(D.suggestedFund) / 2n, 6);
  }

  $('toAddr').value = '';
  validateRecipient();

  $('led').classList.add('on');
  describePriceSource();
  await renderPrices();
  clearInterval(freshTimer);
  freshTimer = setInterval(() => renderPrices().catch(() => {}), 30_000);
  await refreshStatus();
  await loadPositions();
  log(isLocal
    ? 'connected — all assets are mocks on a local chain'
    : `connected to ${D.network} — real tokens and pools, mock price feeds`, 'ok');
}

// ------------------------------------------------------------- freshness ---

const ago = s => s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`;
let freshTimer = null;

async function renderPrices() {
  const assets = [...ASSETS, D.usdg];
  const [blk, cfgs] = await Promise.all([
    pub.getBlock(),
    Promise.all(assets.map((a, i) => pub.readContract({
      address: D.policy, abi: POLICY_ABI,
      functionName: i < ASSETS.length ? 'stockTokenConfig' : 'quoteAssetConfig', args: [a],
    }))),
  ]);
  const rounds = await Promise.all(cfgs.map(c =>
    pub.readContract({ address: c.feed, abi: FEED_ABI, functionName: 'latestRoundData' })));
  const now = Number(blk.timestamp);

  let anyStale = false;
  $('priceRows').innerHTML = assets.map((a, i) => {
    const [, answer, , updatedAt] = rounds[i];
    const age = Math.max(0, now - Number(updatedAt));
    const left = Number(cfgs[i].maxStaleness) - age;
    const state = left < 0 ? 'stale' : left < 600 ? 'soon' : 'ok';
    if (state === 'stale') anyStale = true;
    const when = state === 'stale'
      ? `expired ${ago(-left)} ago — buying paused`
      : `updated ${ago(age)} ago · good for ${ago(left)}`;
    const px = Number(formatUnits(answer, 8)).toLocaleString(NUM, { style: 'currency', currency: 'USD' });
    return `<li data-state="${state}"><span class="dot" aria-hidden="true"></span>
      <span class="sym">${esc(symOf(a))}</span><span class="px">${px}</span>
      <span class="age">${esc(when)}</span></li>`;
  }).join('');

  $('priceRows').setAttribute('aria-label', anyStale ? 'At least one price has expired. Buying is paused.' : 'All prices current.');
}

function describePriceSource() {
  const floorPct = D.maxShortfallBps ? `${D.maxShortfallBps / 100}%` : 'the allowed margin';
  const life = D.feedHeartbeat ? ago(D.feedHeartbeat) : 'its limit';
  if (D.priceSource === 'pool') {
    $('priceSourceTag').textContent = 'read from the pool · demo feed';
    $('aboutPrices').innerHTML = `
      <p>Chainlink publishes no prices on this test network, so Jayo's demo feeds copy the price of the
      same Uniswap pools it buys in. Only the project's keeper can write them, no single update may move
      a price more than 10%, and each one expires after ${esc(life)} — after that, buying pauses until
      the keeper republishes.</p>
      <p><strong>What this protects.</strong> Each slice you buy must arrive within ${esc(floorPct)} of
      the price shown here. The pool's fee and your own purchase pushing the price up are both measured
      against it, and a purchase that would cost more than that is refused before any money moves.</p>
      <p><strong>What it cannot protect.</strong> This price comes from the pool itself, so it cannot
      tell you whether the pool is fairly priced against the real market. If the pool is off, this
      price is off by exactly the same amount and your purchase will still go through. For example, on
      23 September Chainlink's mainnet feed put TSLA at $380.26 while this pool priced it near $256.
      Only a price from outside the pool, such as Chainlink's on mainnet, can catch that.</p>
      <p>Withdrawals never use these prices, so they work even when every price has expired.</p>`;
  } else {
    $('priceSourceTag').textContent = 'demo prices · local chain';
    $('aboutPrices').innerHTML = `
      <p>These are demo prices set by the local demo deployer; only that address can change them.
      Each expires after ${esc(life)}, and buying is refused once any has expired.</p>
      <p><strong>What this protects.</strong> Each slice you buy must arrive within ${esc(floorPct)} of
      these prices, so a pool fee or price impact larger than that stops the purchase.</p>
      <p>Withdrawals never use these prices, so they work even when every price has expired — try
      "Skip forward 48 hours" in the demo controls.</p>`;
  }
}

async function refreshStatus() {
  const [bn, bal] = await Promise.all([
    pub.getBlockNumber(),
    pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'balanceOf', args: [account().address] }),
  ]);
  const who = isLocal ? `${ACCOUNTS[acctIndex].label} ${short(account().address)}` : `${short(account().address)} (${signerLabel})`;
  const unit = META[D.usdg.toLowerCase()]?.symbol || 'USDG';
  $('netmeta').textContent =
    `${isLocal ? 'local chain' : D.network} ${D.chainId} · block ${bn} · ${who} · ${usdg(bal)} ${unit}`;
  $('livetext').textContent = 'live';
}

// ------------------------------------------------------- allocation rows ----

function renderRows() {
  const host = $('allocRows');
  host.innerHTML = '';
  rows.forEach((r, i) => {
    const m = META[r.asset.toLowerCase()];
    const div = document.createElement('div');
    div.className = 'alloc-row';
    div.innerHTML = `
      <div class="asset">
        <span class="chip" aria-hidden="true">${esc(m.symbol.slice(0, 4))}</span>
        <span><span class="sym">${esc(m.symbol)}</span><br><span class="name">${esc(m.name)}</span></span>
      </div>
      <div class="field">
        <label for="pct${i}">Share</label>
        <input id="pct${i}" type="number" min="0" max="100" step="1" value="${r.pct}"
               aria-label="${esc(m.symbol)} share, percent" />
      </div>`;
    host.appendChild(div);
    div.querySelector('input').addEventListener('input', ev => {
      rows[i].pct = Number(ev.target.value || 0);
      updateTotal();
    });
  });
  updateTotal();
}

function updateTotal() {
  const total = rows.reduce((s, r) => s + (Number(r.pct) || 0), 0);
  const line = $('totalLine');
  $('totalPct').textContent = `${total}%`;
  line.classList.toggle('bad', total !== 100);
  line.classList.toggle('good', total === 100);
  line.firstElementChild.textContent = total === 100
    ? 'Allocations add up to 100%'
    : `Allocations must add up to 100% — currently ${total}%`;
  $('btnCreate').disabled = total !== 100;
  rows.forEach((_, i) => $(`pct${i}`)?.setAttribute('aria-invalid', total !== 100 ? 'true' : 'false'));

  // A success notice from the previous basket sitting next to a now-disabled
  // button reads as if this edit succeeded. Clear it as soon as the form moves.
  clearMsg('createMsg', 'quote');
}

const allocArg = () => rows.map(r => ({ asset: r.asset, weightBps: Math.round(r.pct * 100) }));
// Deadlines must come from CHAIN time, never the browser clock. The two can
// differ by a lot - this demo's chain runs ahead after the "skip 48 hours"
// control, and on a real network a user's clock can simply be wrong. Using
// Date.now() produced an immediate IntentExpired with no obvious cause.
async function deadline() {
  // On anvil the latest block can be hours old if nothing has been mined, and the
  // next block's timestamp then jumps past any deadline derived from it - create
  // failed with IntentExpired after the demo chain sat idle. Mining an empty block
  // first makes "latest" mean now. Public chains produce blocks continuously, so
  // this is local only.
  if (isLocal) await pub.request({ method: 'evm_mine', params: [] });
  const blk = await pub.getBlock();
  return blk.timestamp + 3600n;
}
const fundAmount = () => parseUnits(String($('fund').value || '0').replace(/,/g, ''), 6);
$('fund').addEventListener('input', () => clearMsg('createMsg', 'quote'));

// ------------------------------------------------------------------ quote ---

$('btnQuote').addEventListener('click', async () => {
  clearMsg('createMsg');
  const btn = $('btnQuote');
  busy(btn, true, 'Checking…');
  try {
    const amount = fundAmount();
    const [ins, refs, floors, unspent] = await pub.readContract({
      address: D.basket, abi: BASKET_ABI, functionName: 'previewCreate',
      args: [allocArg(), amount],
    });

    const lines = rows.map((r, i) => {
      const m = META[r.asset.toLowerCase()];
      return `<dt>${esc(m.symbol)} — you pay ${usdg(ins[i])} USDG</dt>
              <dd>about ${tok(refs[i])}<br>
                  <span style="color:var(--fog);font-size:12px">at least ${tok(floors[i])}</span></dd>`;
    }).join('');

    $('quote').innerHTML = `
      <div class="summary">
        <dl>
          <dt>You pay</dt><dd class="big">${usdg(amount)} USDG</dd>
          <div class="sep"></div>
          ${lines}
          <div class="sep"></div>
          <dt>Left over, returned to you</dt><dd>${usdg(unspent)} USDG</dd>
          <p class="note">
            “About” is today’s fair price. “At least” is the minimum we will accept —
            if the market gives less than that, the whole purchase is cancelled and
            you keep your money. The small gap between them is the trading fee.
          </p>
        </dl>
      </div>`;
    log('quote loaded', 'ok');
  } catch (e) {
    $('quote').innerHTML = '';
    showError('createMsg', e);
  } finally { busy(btn, false); }
});

// ----------------------------------------------------------------- create ---

$('btnCreate').addEventListener('click', async () => {
  clearMsg('createMsg');
  const btn = $('btnCreate');
  busy(btn, true, 'Creating…');
  try {
    const amount = fundAmount();
    const w = wallet();

    const allowance = await pub.readContract({
      address: D.usdg, abi: ERC20_ABI, functionName: 'allowance',
      args: [account().address, D.basket],
    });
    if (allowance < amount) {
      tx('createTx', 'signing', 'Allowing Jayo to use your USDG…');
      const ah = await w.writeContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'approve', args: [D.basket, parseUnits('1000000000', 6)] });
      tx('createTx', 'pending', 'Waiting for confirmation…');
      await pub.waitForTransactionReceipt({ hash: ah });
    }

    tx('createTx', 'signing', 'Buying your tokens…');
    const hash = await w.writeContract({
      address: D.basket, abi: BASKET_ABI, functionName: 'create',
      args: [allocArg(), amount, await deadline()],
    });
    tx('createTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('createTx', 'confirmed', 'Done');

    showOk('createMsg', 'Your basket is ready.', 'It is listed below with what it actually holds.');
    log('basket created', 'ok');
    $('quote').innerHTML = '';
    await refreshStatus();
    await loadPositions();
  } catch (e) {
    tx('createTx', 'failed', 'Cancelled — nothing was spent');
    showError('createMsg', e);
  } finally { busy(btn, false); }
});

// -------------------------------------------------------------- positions ---

async function loadPositions() {
  const host = $('positions');
  host.innerHTML = '';
  const me = account().address.toLowerCase();
  let found = 0;

  for (let id = 1n; id <= 40n; id++) {
    let owner;
    try { owner = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'ownerOf', args: [id] }); }
    catch { continue; }
    found++;

    const [assets, amounts] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [id] });
    const mine = owner.toLowerCase() === me;
    const list = assets.map((a, i) => `${esc(symOf(a))} ${tok(amounts[i])}`).join(' · ');

    const el = document.createElement('article');
    el.className = 'position';
    el.innerHTML = `
      <h3>Basket #${id}
        <span class="badge ${mine ? 'yours' : ''}">${mine ? 'Yours' : 'Someone else’s'}</span></h3>
      <p class="owner">owner ${short(owner)}</p>
      <p style="font-family:var(--mono);font-size:13px;color:var(--ice);margin:10px 0 14px">${list || 'empty'}</p>
      <button class="quiet" type="button" data-id="${id}">Open</button>`;
    el.querySelector('button').addEventListener('click', () => selectPosition(id));
    host.appendChild(el);
  }
  $('posEmpty').hidden = found > 0;
  if (selectedId !== null) await selectPosition(selectedId, true);
}

async function selectPosition(id, quiet = false) {
  selectedId = id;
  const [assets, amounts] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [BigInt(id)] });
  const owner = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'ownerOf', args: [BigInt(id)] });
  const alloc = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'allocationOf', args: [BigInt(id)] });

  $('detailCard').hidden = false;
  $('detailId').textContent = `#${id}`;
  const mine = owner.toLowerCase() === account().address.toLowerCase();
  $('detailOwner').innerHTML = mine
    ? `You own this basket.`
    : `Owned by ${esc(short(owner))} — you are viewing it, not controlling it.`;

  $('detailRows').innerHTML = assets.map((a, i) => {
    const w = alloc.find(x => x.asset.toLowerCase() === a.toLowerCase());
    return `<tr><td>${esc(symOf(a))}<br><span style="color:var(--fog);font-size:12px">${esc(META[a.toLowerCase()]?.name || '')}</span></td>
      <td class="num">${tok(amounts[i])}</td>
      <td class="num">${w ? (Number(w.weightBps) / 100).toFixed(0) + '%' : '—'}</td></tr>`;
  }).join('') || `<tr><td colspan="3" style="color:var(--fog)">This basket has been emptied.</td></tr>`;

  let notes = '';
  // After a partial withdrawal the recipe and the holdings say different things,
  // and both are true. Say which is which rather than letting the table imply
  // the basket still holds a leg it no longer has.
  const missing = alloc.filter(x => !assets.some(a => a.toLowerCase() === x.asset.toLowerCase()));
  if (missing.length && assets.length) {
    notes += `<div class="msg info"><span class="icon">i</span><div class="body">
       <strong>You have taken ${missing.map(m => esc(symOf(m.asset))).join(' and ')} out of this basket.</strong><br>
       The recipe still lists it, because that is the split this basket was built from and the one
       anyone copying it would use. What it holds now is the table above.</div></div>`;
  }
  $('detailNotes').innerHTML = notes;

  ['btnRedeem', 'btnRedeemPart'].forEach(b => { $(b).disabled = !mine; });
  $('toAddr').disabled = !mine;
  hideTransferConfirm();
  validateRecipient();
  $('redeemPart').disabled = !mine;

  // Offer each leg by name alongside the proportional options, so "give me my
  // NVDA back" is one click rather than a calculation.
  const sel = $('redeemPart');
  const keep = sel.value;
  sel.innerHTML =
    `<option value="frac:2500">A quarter of every token</option>` +
    `<option value="frac:5000">Half of every token</option>` +
    assets.map(a => `<option value="asset:${a}">All of my ${esc(symOf(a))}, and nothing else</option>`).join('');
  if ([...sel.options].some(o => o.value === keep)) sel.value = keep;
  if (!quiet) {
    log(`opened basket #${id}`);
    clearMsg('receipt');
    // Keyboard users pressed Open and the panel appeared somewhere below them.
    // Move the reading position to it, the same way the mouse user's eye does.
    const h = $('h-detail');
    h.setAttribute('tabindex', '-1');
    h.focus({ preventScroll: false });
  }
}

// --------------------------------------------------------------- transfer ---
//
// There is no default recipient. An earlier version pre-filled a fixed address,
// which on a public deployment meant one mis-click handed a real position to a
// stranger. The address is typed or pasted, validated as it is entered, and
// nothing is signed until a separate confirmation names the full address and the
// holdings being given away.

let recipient = null; // checksummed; set only while the input is valid

function hintRecipient(text, bad) {
  const h = $('toAddrHint');
  h.textContent = text;
  h.style.color = bad ? 'var(--danger)' : '';
  $('toAddr').setAttribute('aria-invalid', bad ? 'true' : 'false');
}

function validateRecipient() {
  recipient = null;
  const raw = $('toAddr').value.trim();
  const mine = selectedId !== null && !$('toAddr').disabled;
  $('btnTransfer').disabled = true;

  if (!raw) return hintRecipient('Paste the address of the person receiving it.', false);
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    return hintRecipient('That is not a wallet address. It should be 0x followed by 40 letters and numbers.', true);
  }
  // A mixed-case address carries a checksum; one wrong character breaks it.
  const body = raw.slice(2);
  const mixed = body !== body.toLowerCase() && body !== body.toUpperCase();
  if (mixed && !isAddress(raw, { strict: true })) {
    return hintRecipient('This address has a typo: its capital letters do not match its checksum. Copy it again.', true);
  }
  const addr = getAddress(raw);
  if (/^0x0{40}$/i.test(addr)) return hintRecipient('That is the zero address. Anything sent there is gone for good.', true);
  if (addr.toLowerCase() === account().address.toLowerCase()) return hintRecipient('That is your own address.', true);
  const known = [D.basket, D.usdg, D.gateway, D.policy, D.adapter, D.poolManager, ...(D.stocks || [])]
    .filter(Boolean).map(a => a.toLowerCase());
  if (known.includes(addr.toLowerCase())) {
    return hintRecipient("That is one of Jayo's own contracts, not a person. It could never give the basket back.", true);
  }
  recipient = addr;
  hintRecipient('Looks like a valid address. You will be asked to confirm before anything is sent.', false);
  $('btnTransfer').disabled = !mine;
}

function hideTransferConfirm() {
  $('transferConfirm').hidden = true;
  $('tcAck').checked = false;
  $('btnTransferConfirm').disabled = true;
}

$('toAddr').addEventListener('input', () => { hideTransferConfirm(); clearMsg('transferMsg'); validateRecipient(); });

$('btnTransfer').addEventListener('click', async () => {
  validateRecipient();
  if (!recipient) return;
  const [assets, amounts] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [BigInt(selectedId)] });
  const code = await pub.getCode({ address: recipient });

  $('tcId').textContent = `#${selectedId}`;
  $('tcHoldings').textContent = assets.length
    ? assets.map((a, i) => `${tok(amounts[i])} ${symOf(a)}`).join(' and ')
    : 'nothing (it is empty)';
  $('tcAddr').textContent = recipient;
  $('tcWarn').textContent = code && code !== '0x'
    ? 'This address is a contract, not a personal wallet. If it cannot hold baskets the hand-over will be refused and nothing will move.'
    : '';
  $('transferConfirm').hidden = false;
  $('tcAck').focus();
});

$('tcAck').addEventListener('change', () => { $('btnTransferConfirm').disabled = !$('tcAck').checked; });
$('btnTransferCancel').addEventListener('click', () => { hideTransferConfirm(); $('btnTransfer').focus(); });

$('btnTransferConfirm').addEventListener('click', async () => {
  if (!recipient || !$('tcAck').checked) return;
  clearMsg('transferMsg');
  const to = recipient;
  const btn = $('btnTransferConfirm'); busy(btn, true, 'Handing over…');
  try {
    tx('transferTx', 'signing', 'Handing over the basket…');
    // safeTransferFrom, not transferFrom: a contract that cannot hold ERC-721s
    // makes the hand-over revert instead of swallowing the basket.
    const hash = await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'safeTransferFrom', args: [account().address, to, BigInt(selectedId)] });
    tx('transferTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('transferTx', 'confirmed', 'Done');
    showOk('transferMsg', `Basket #${selectedId} now belongs to ${to}.`,
      'You can no longer withdraw from it or hand it on.');
    log(`basket #${selectedId} handed to ${short(to)} · tx ${short(hash)}`, 'ok');
    hideTransferConfirm();
    $('toAddr').value = '';
    await loadPositions();
  } catch (e) { tx('transferTx', 'failed', 'Cancelled — nothing moved'); showError('transferMsg', e); }
  finally { busy(btn, false); }
});

// ------------------------------------------------------------------- copy ---

$('btnCopy').addEventListener('click', async () => {
  clearMsg('copyMsg');
  const btn = $('btnCopy'); busy(btn, true, 'Copying…');
  try {
    const amount = parseUnits(String($('copyFund').value || '0').replace(/,/g, ''), 6);
    const w = wallet();
    const allowance = await pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'allowance', args: [account().address, D.basket] });
    if (allowance < amount) {
      tx('copyTx', 'signing', 'Allowing Jayo to use your USDG…');
      const ah = await w.writeContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'approve', args: [D.basket, parseUnits('1000000000', 6)] });
      await pub.waitForTransactionReceipt({ hash: ah });
    }
    tx('copyTx', 'signing', 'Buying the same mix for you…');
    const hash = await w.writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'copyAllocation', args: [BigInt(selectedId), amount, await deadline()] });
    tx('copyTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('copyTx', 'confirmed', 'Done');
    showOk('copyMsg', 'You now own a basket with the same mix.',
      'It was bought with your money. The original owner keeps everything of theirs.');
    log(`copied basket #${selectedId} with your own funds`, 'ok');
    await refreshStatus(); await loadPositions();
  } catch (e) { tx('copyTx', 'failed', 'Cancelled — nothing was spent'); showError('copyMsg', e); }
  finally { busy(btn, false); }
});

// ----------------------------------------------------------------- redeem ---

$('btnRedeem').addEventListener('click', async () => {
  clearMsg('redeemMsg');
  const btn = $('btnRedeem'); busy(btn, true, 'Withdrawing…');
  try {
    const [assets, amounts] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [BigInt(selectedId)] });
    tx('redeemTx', 'signing', 'Sending your tokens…');
    const hash = await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'redeem', args: [BigInt(selectedId)] });
    tx('redeemTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('redeemTx', 'confirmed', 'Done');
    const got = assets.map((a, i) => `${tok(amounts[i])} ${symOf(a)}`).join(' and ');
    log(`basket #${selectedId} withdrawn in kind`, 'ok');
    // The receipt goes above, not here: this card is about to disappear.
    showOk('receipt', `Basket #${selectedId} closed. Sent ${got} to your wallet.`,
      'No price was needed for this, which is why it works when markets are closed.');
    clearMsg('redeemMsg');
    selectedId = null; $('detailCard').hidden = true;
    await loadPositions();
    // Jump rather than smooth-scroll: the relayout from closing the detail card
    // cancels an in-flight smooth scroll and leaves the receipt below the fold.
    // setTimeout, not requestAnimationFrame — rAF is paused while the tab is in
    // the background, so the scroll would silently never happen.
    setTimeout(() => $('receipt').scrollIntoView({ block: 'center', behavior: 'auto' }), 0);
  } catch (e) { tx('redeemTx', 'failed', 'Cancelled'); showError('redeemMsg', e); }
  finally { busy(btn, false); }
});

$('btnRedeemPart').addEventListener('click', async () => {
  clearMsg('redeemMsg');
  const btn = $('btnRedeemPart'); busy(btn, true, 'Withdrawing…');
  try {
    const [kind, value] = $('redeemPart').value.split(':');
    const before = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [BigInt(selectedId)] });

    tx('redeemTx', 'signing', 'Sending your tokens…');
    const hash = kind === 'asset'
      ? await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'redeemAsset', args: [BigInt(selectedId), value] })
      : await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'redeemFraction', args: [BigInt(selectedId), Number(value)] });
    tx('redeemTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('redeemTx', 'confirmed', 'Done');

    // Report what actually moved, read back from the contract rather than
    // predicted - the same rule the rest of this page follows.
    const after = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'holdingsOf', args: [BigInt(selectedId)] });
    const sent = before[0]
      .map((a, i) => [a, before[1][i] - (after[0].indexOf(a) === -1 ? 0n : after[1][after[0].indexOf(a)])])
      .filter(([, d]) => d > 0n)
      .map(([a, d]) => `${tok(d)} ${symOf(a)}`)
      .join(' and ');

    showOk('redeemMsg', `Sent ${sent} to your wallet.`,
      'The basket is still yours and still holds the rest. No price was needed for this.');
    log(`partial withdrawal from basket #${selectedId}`, 'ok');
    await selectPosition(selectedId, true);
    await refreshStatus();
    await loadPositions();
  } catch (e) { tx('redeemTx', 'failed', 'Cancelled — nothing was sent'); showError('redeemMsg', e); }
  finally { busy(btn, false); }
});

// ------------------------------------------------------------ demo panel ----

// Local chain only: the demo panel is hidden on any public network.
$('btnFillOther').addEventListener('click', () => {
  $('toAddr').value = privateKeyToAccount(ACCOUNTS[(acctIndex + 1) % ACCOUNTS.length].key).address;
  $('toAddr').dispatchEvent(new Event('input'));
  $('toAddr').focus();
});

$('btnAcct').addEventListener('click', async () => {
  acctIndex = (acctIndex + 1) % ACCOUNTS.length;
  await refreshStatus(); await loadPositions();
  $('demoMsg').innerHTML = `<div class="msg info"><span class="icon">i</span><div class="body">
    Now acting as <strong>${esc(ACCOUNTS[acctIndex].label)}</strong> (${esc(short(account().address))}).</div></div>`;
  log(`switched to ${ACCOUNTS[acctIndex].label}`);
});

$('btnTime').addEventListener('click', async () => {
  await pub.request({ method: 'evm_increaseTime', params: [172800] });
  await pub.request({ method: 'evm_mine', params: [] });
  const [, , , updatedAt] = await pub.readContract({ address: D.aaplFeed, abi: FEED_ABI, functionName: 'latestRoundData' });
  const blk = await pub.getBlock();
  const hrs = (Number(blk.timestamp - updatedAt) / 3600).toFixed(1);
  $('demoMsg').innerHTML = `<div class="msg warn"><span class="icon">!</span><div class="body">
    <strong>Prices are now ${esc(hrs)} hours old.</strong><br>
    This is what a weekend looks like: stock prices stop updating. Try creating a
    basket — it will refuse. Then withdraw from one you own — it still works.</div></div>`;
  await refreshStatus();
  await renderPrices();
  log(`time advanced; feeds ${hrs}h old`);
});

$('btnPause').addEventListener('click', async () => {
  const paused = await pub.readContract({ address: D.aapl, abi: ERC20_ABI, functionName: 'oraclePaused' });
  const hash = await wallet().writeContract({ address: D.aapl, abi: ERC20_ABI, functionName: 'setOraclePaused', args: [!paused] });
  await pub.waitForTransactionReceipt({ hash });
  $('demoMsg').innerHTML = `<div class="msg warn"><span class="icon">!</span><div class="body">
    <strong>${esc(symOf(D.aapl))}’s price oracle is ${!paused ? 'paused' : 'live again'}.</strong><br>
    Issuers pause these around dividends and share splits. Buying that token is blocked
    while paused; withdrawing is not.</div></div>`;
  log(`oracle paused = ${!paused}`);
});

$('btnRefresh').addEventListener('click', async () => {
  // Three sequential transactions. Without a busy state the operator can fire
  // "Create basket" into a half-refreshed set of feeds and get a confusing
  // FeedStale naming a feed that is about to be fine.
  const btn = $('btnRefresh'); busy(btn, true, 'Refreshing…');
  try {
    // The feeds only accept their owner (the local deployer, Wallet A), so this
    // signs as Wallet A whichever wallet the page is currently acting as.
    const w = createWalletClient({ account: privateKeyToAccount(LOCAL_ACCOUNTS[0].key), chain, transport: http('http://127.0.0.1:8545') });
    for (const [feed, price] of [[D.aaplFeed, 255_00000000n], [D.nvdaFeed, 150_00000000n], [D.usdgFeed, 1_00000000n]]) {
      const h = await w.writeContract({ address: feed, abi: FEED_ABI, functionName: 'setAnswer', args: [price] });
      await pub.waitForTransactionReceipt({ hash: h });
    }
    $('demoMsg').innerHTML = `<div class="msg success"><span class="icon">✓</span><div class="body">
      <strong>Prices are current again.</strong> Buying works.</div></div>`;
    log('feeds refreshed', 'ok');
    await renderPrices();
  } catch (e) { showError('demoMsg', e); }
  finally { busy(btn, false); }
});

$('btnReload').addEventListener('click', async () => { await refreshStatus(); await loadPositions(); log('state reloaded'); });

boot();
