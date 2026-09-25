// =============================================================================
// Jayo interface
//
// Design goals, in priority order:
//   1. A basket is the product. Anyone who lands on one - by link, from a card -
//      can see exactly what it holds, how new money into it is split, who owns
//      it, what has happened to it, and what THEY can do with it.
//   2. The page moves only on real state. An addition is previewed from the
//      contract's own quote (drawn dashed and called an estimate), then walks
//      through its real steps - permission, wallet, pending, confirmed or
//      failed - and only a confirmed receipt changes the basket on screen,
//      showing what was actually bought beside what was estimated.
//   3. Every rejection says, in plain words, what happened and what to change.
//
// Three contracts are read. Version 3 is where everything new happens: buying,
// adding money or Stock Tokens held, copying. Versions 1 and 2 are immutable,
// withdraw-only on chain, and stay listed: their baskets can be taken out of and
// handed on, and their plans copied into a new version-3 basket.
//
// The same file serves the local demo (mock assets, demo controls) and the
// HOSTED site (the visitor's own browser wallet). scripts/build-site.mjs removes
// the local-only blocks and refuses a hosted build that still contains a key or
// the local test signer.
// =============================================================================

// viem 2.21.55, bundled locally by tools/build-vendor.mjs: the page loads no code
// from any other origin.
import {
  createPublicClient, createWalletClient, http, custom, parseUnits, formatUnits,
  isAddress, getAddress, parseEventLogs,
} from '/app/vendor/viem.js';
/* @local-only-start */
import { privateKeyToAccount, foundry } from '/app/vendor/viem.js';
/* @local-only-end */

let isLocal = false;
let chain = null;
let pub = null;
let injected = null;         // viem wallet client backed by the visitor's wallet
let injectedAddress = null;  // null until the visitor connects
let LOCAL = null;            // the local demo's hooks; present only in the local build

/* @local-only-start */
// Anvil's deterministic accounts. Published in Foundry's documentation and worth
// nothing anywhere. Used ONLY when the deployment is chainId 31337; the hosted
// build does not contain them.
const LOCAL_ACCOUNTS = [
  { label: 'Wallet A', key: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' },
  { label: 'Wallet B', key: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' },
];
let acctIndex = 0;
LOCAL = {
  chain: foundry,
  rpc: 'http://127.0.0.1:8545',
  account: () => privateKeyToAccount(LOCAL_ACCOUNTS[acctIndex].key),
  wallet: () => createWalletClient({ account: privateKeyToAccount(LOCAL_ACCOUNTS[acctIndex].key), chain, transport: http('http://127.0.0.1:8545') }),
  label: () => LOCAL_ACCOUNTS[acctIndex].label,
  // An idle anvil's latest block can be hours old; mine one so "latest" means now.
  freshBlock: () => pub.request({ method: 'evm_mine', params: [] }),
};
/* @local-only-end */

/** The acting account, or null on a public network before the visitor connects. */
const account = () => (isLocal ? LOCAL.account() : (injectedAddress ? { address: injectedAddress } : null));
const wallet = () => (isLocal ? LOCAL.wallet() : injected);
const connected = () => account() !== null;
const me = () => account()?.address?.toLowerCase() ?? '';

// ---------------------------------------------------------------- ABIs ------

const ALLOC = { type: 'tuple[]', components: [{ name: 'asset', type: 'address' }, { name: 'weightBps', type: 'uint16' }] };
const ERRORS = [
  ['LegBelowMinimum', ['address', 'uint256', 'uint256']], ['LegWouldAcquireNothing', ['address', 'uint256']],
  ['LegAcquiredNothing', ['address', 'uint256']], ['WeightsMustSumToBps', ['uint256']], ['DuplicateAsset', ['address']],
  ['AssetNotSupported', ['address']], ['NoLegs', []], ['TooManyLegs', ['uint256', 'uint256']],
  ['NotPositionOwner', ['uint256', 'address']], ['AssetNotHeld', ['uint256', 'address']], ['FractionOutOfRange', ['uint16']],
  ['FractionWouldDeliverNothing', ['uint256', 'uint16']], ['AllocationChangedSinceQuote', ['uint256', 'uint64', 'uint64']],
  ['OwnerChangedSinceQuote', ['uint256', 'address', 'address']], ['LengthMismatch', ['uint256', 'uint256']],
  ['NothingReceived', ['address', 'uint256']],
  ['PositionDoesNotExist', ['uint256']], ['ZeroAmount', []],
  ['OutputBelowFloor', ['uint256', 'uint256']], ['InputOverspent', ['uint256', 'uint256']], ['IntentExpired', ['uint256', 'uint256']],
  ['FeedStale', ['address', 'uint256', 'uint256', 'uint256']], ['FeedAnswerNotPositive', ['address', 'int256']],
  ['OraclePausedForCorporateAction', ['address']], ['CorporateActionPending', ['address', 'uint256', 'uint256']],
  ['TokenNotSupported', ['address']], ['ERC721InsufficientApproval', ['address', 'uint256']], ['ERC721InvalidReceiver', ['address']],
  ['ERC721IncorrectOwner', ['address', 'uint256', 'address']], ['ERC721NonexistentToken', ['uint256']],
  ['ERC20InsufficientAllowance', ['address', 'uint256', 'uint256']], ['ERC20InsufficientBalance', ['address', 'uint256', 'uint256']],
].map(([name, ins]) => ({ type: 'error', name, inputs: ins.map(type => ({ type })) }));

const fn = (name, inputs, outputs = [], stateMutability = 'nonpayable') =>
  ({ type: 'function', name, stateMutability, inputs: inputs.map(t => (typeof t === 'string' ? { type: t } : t)), outputs: outputs.map(t => (typeof t === 'string' ? { type: t } : t)) });
const view = (name, inputs, outputs) => fn(name, inputs, outputs, 'view');

const EVENTS = [
  { type: 'event', name: 'BasketCreated', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'creator', type: 'address', indexed: true },
    { name: 'usdgFunded', type: 'uint256' }, { name: 'usdgSpent', type: 'uint256' }, { name: 'usdgReturned', type: 'uint256' }, { name: 'legCount', type: 'uint256' }] },
  { type: 'event', name: 'Contributed', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'contributor', type: 'address', indexed: true },
    { name: 'usdgFunded', type: 'uint256' }, { name: 'usdgSpent', type: 'uint256' }, { name: 'allocationVersion', type: 'uint64' }] },
  { type: 'event', name: 'DepositedInKind', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'depositor', type: 'address', indexed: true },
    { name: 'asset', type: 'address', indexed: true }, { name: 'amount', type: 'uint256' }] },
  { type: 'event', name: 'LegSettled', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'asset', type: 'address', indexed: true },
    { name: 'weightBps', type: 'uint16' }, { name: 'usdgSpent', type: 'uint256' }, { name: 'acquired', type: 'uint256' }] },
  { type: 'event', name: 'AllocationChanged', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'version', type: 'uint64' }, { name: 'allocation', ...ALLOC }] },
  { type: 'event', name: 'AssetRedeemed', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'asset', type: 'address', indexed: true },
    { name: 'to', type: 'address', indexed: true }, { name: 'amount', type: 'uint256' }] },
  { type: 'event', name: 'PositionClosed', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'lastOwner', type: 'address', indexed: true }] },
  { type: 'event', name: 'BasketRedeemed', inputs: [{ name: 'tokenId', type: 'uint256', indexed: true }, { name: 'to', type: 'address', indexed: true }, { name: 'legCount', type: 'uint256' }] },
  { type: 'event', name: 'AllocationCopied', inputs: [{ name: 'sourceTokenId', type: 'uint256', indexed: true }, { name: 'newTokenId', type: 'uint256', indexed: true },
    { name: 'creator', type: 'address', indexed: true }] },
  { type: 'event', name: 'Transfer', inputs: [{ name: 'from', type: 'address', indexed: true }, { name: 'to', type: 'address', indexed: true }, { name: 'tokenId', type: 'uint256', indexed: true }] },
];

const READS = [
  view('holdingsOf', ['uint256'], ['address[]', 'uint256[]']),
  view('allocationOf', ['uint256'], [{ ...ALLOC }]),
  view('ownerOf', ['uint256'], ['address']),
];
const COUNTERS = [
  view('allocationVersion', ['uint256'], ['uint64']),
  view('totalFunded', ['uint256'], ['uint256']),
  view('fundingCount', ['uint256'], ['uint32']),
  view('firstTokenId', [], ['uint256']),
  view('nextTokenId', [], ['uint256']),
];
const EXITS = [
  fn('safeTransferFrom', ['address', 'address', 'uint256']),
  fn('redeem', ['uint256']),
  fn('redeemAsset', ['uint256', 'address']),
  fn('redeemFraction', ['uint256', 'uint16']),
];
// Version 3: everything the page reads and writes on a current basket.
const BASKET_ABI = [
  ...READS, ...COUNTERS, ...EXITS,
  view('previewCreate', [{ name: 'allocation', ...ALLOC }, 'uint256'], ['uint256[]', 'uint256[]', 'uint256[]', 'uint256']),
  view('previewContribute', ['uint256', 'uint256'], ['uint256[]', 'uint256[]', 'uint256[]', 'uint256']),
  view('minLegInput', [], ['uint256']),
  fn('create', [{ name: 'allocation', ...ALLOC }, 'uint256', 'uint256'], ['uint256']),
  fn('contribute', ['uint256', 'uint256', 'address', 'uint64', 'uint256']),
  fn('copyAllocation', ['uint256', 'uint256', 'uint64', 'uint256'], ['uint256']),
  fn('createInKind', [{ name: 'allocation', ...ALLOC }, 'address[]', 'uint256[]'], ['uint256']),
  fn('depositInKind', ['uint256', 'address', 'address[]', 'uint256[]']),
  fn('setAllocation', ['uint256', { name: 'allocation', ...ALLOC }]),
  ...ERRORS, ...EVENTS,
];
// Earlier versions: read, take out, hand on. Nothing that buys.
const LEGACY1_ABI = [...READS, ...EXITS, ...ERRORS, ...EVENTS];
const LEGACY2_ABI = [...READS, ...COUNTERS, ...EXITS, ...ERRORS, ...EVENTS];

const ERC20_ABI = [
  fn('approve', ['address', 'uint256'], ['bool']),
  view('balanceOf', ['address'], ['uint256']),
  view('allowance', ['address', 'address'], ['uint256']),
  view('symbol', [], ['string']),
  view('name', [], ['string']),
  fn('mint', ['address', 'uint256']), // the testnet rUSDG mints to anyone
  ...ERRORS,
];
const FEED_ABI = [
  view('latestRoundData', [], ['uint80', 'int256', 'uint256', 'uint256', 'uint80']),
  fn('setAnswer', ['int256']),
];
// The policy is the source of truth for which feed prices which asset and how old
// it may be, so the freshness shown is exactly what a purchase is checked against.
const POLICY_ABI = [
  view('stockTokenConfig', ['address'], [{ type: 'tuple', components: [
    { name: 'feed', type: 'address' }, { name: 'maxStaleness', type: 'uint32' }, { name: 'maxShortfallBps', type: 'uint16' },
    { name: 'tokenDecimals', type: 'uint8' }, { name: 'hasOraclePaused', type: 'bool' }, { name: 'hasCorporateActionData', type: 'bool' }] }]),
  view('quoteAssetConfig', ['address'], [{ type: 'tuple', components: [
    { name: 'feed', type: 'address' }, { name: 'maxStaleness', type: 'uint32' }, { name: 'tokenDecimals', type: 'uint8' }] }]),
];

// ----------------------------------------------------------------- state ----

let D = null;                 // the deployment manifest
const META = {};              // address -> { symbol, name, color }
let ASSETS = [];              // Stock Tokens this deployment supports
let PRICES = {};              // address -> { price8, updatedAt, maxStale }
let buyingOpen = false;
let CONTRACTS = [];           // [{ version, address, abi, first, end, legacy, deployBlock, counters, enumerate }]
let baskets = [];             // every live basket, all versions
let current = null;           // the basket on screen
let minLeg = 1_000000n;
const PALETTE = ['#0B5563', '#EE6A4C', '#E6B23A', '#5B9FD1', '#7E5AA2', '#3E9E86', '#C7577A', '#8A6D52'];
const NUM = 'en-US';          // one locale, so separators never mix in a sentence
const REDUCED = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const short = a => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '—');
/** A shortened address as HTML, in the address face. */
const addrHtml = a => `<span class="mono-addr" title="${esc(a)}">${esc(short(a))}</span>`;
const stableSym = () => META[D?.usdg?.toLowerCase()]?.symbol || 'USDG';
const usdg = v => Number(formatUnits(BigInt(v), 6)).toLocaleString(NUM, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
/// Token amounts are TRUNCATED to 6 decimals, never rounded up: a basket is never
/// shown holding more than it does. Same rule as the on-chain renderer.
const tok = v => {
  const [whole, frac = ''] = formatUnits(BigInt(v), 18).split('.');
  const f = frac.slice(0, 6).replace(/0+$/, '');
  const w = BigInt(whole).toLocaleString(NUM);
  if (!f && BigInt(v) > 0n && whole === '0') return '<0.000001';
  return f ? `${w}.${f}` : w;
};
const usd = n => n.toLocaleString(NUM, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
const symOf = a => META[String(a).toLowerCase()]?.symbol || short(a);
const colorOf = a => META[String(a).toLowerCase()]?.color || '#7C8E95';
const ago = s => (s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`);
const txUrl = hash => (D?.explorer && hash ? `${D.explorer}/tx/${hash}` : null);
const valueOf = (asset, amount) => {
  const p = PRICES[String(asset).toLowerCase()];
  return p ? Number(formatUnits(BigInt(amount), 18)) * Number(formatUnits(p.price8, 8)) : 0;
};
const basketUrl = b => `?basket=${b.id}`;
const isMine = b => connected() && b.owner?.toLowerCase() === me();
const sleep = ms => new Promise(r => setTimeout(r, ms));

function log(msg, cls = '', hash = null) {
  const li = document.createElement('li');
  if (cls) li.className = cls;
  li.textContent = `${new Date().toLocaleTimeString(NUM)}  ${msg}`;
  const url = txUrl(hash);
  if (url) {
    const a = document.createElement('a');
    a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = ` · receipt ${short(hash)}`;
    li.appendChild(a);
  }
  $('log').appendChild(li);
}

// ------------------------------------------------------------ plain words ---

const PLAIN = {
  ERC721InvalidReceiver: a => (String(a[0]).toLowerCase() === me()
    ? { title: 'Your wallet cannot hold baskets.', fix: 'It is a smart-contract account that does not accept this kind of token (ERC-721), so nothing was created and nothing was spent. Use an ordinary wallet.' }
    : { title: `${short(a[0])} is a contract that cannot hold baskets.`, fix: "Nothing was sent. Hand it to a person's wallet address instead." }),
  ERC721IncorrectOwner: () => ({ title: 'You no longer own this basket.', fix: 'It may already have been handed on. Reload to see its owner.' }),
  ERC721NonexistentToken: a => ({ title: `Basket #${a[0]} does not exist any more.`, fix: 'It was closed when its last holding was taken out. Nothing was spent.' }),
  AssetNotHeld: a => ({ title: `This basket holds no ${symOf(a[1])}.`, fix: 'That one has already been taken out. Choose another option.' }),
  FractionOutOfRange: () => ({ title: 'That is not a share you can take out.', fix: 'Choose one of the options shown.' }),
  FractionWouldDeliverNothing: () => ({ title: 'That share is too small to move anything.', fix: 'Take out a bigger share, or everything.' }),
  WeightsMustSumToBps: a => ({ title: `The mix adds up to ${(Number(a[0]) / 100).toFixed(0)}%.`, fix: 'It needs to total exactly 100%.' }),
  LegBelowMinimum: a => ({ title: `The ${symOf(a[0])} part is only ${usdg(a[1])} ${stableSym()}.`, fix: `Each Stock Token needs at least ${usdg(a[2])} ${stableSym()}. Put in more, or give it a bigger share.` }),
  LegWouldAcquireNothing: a => ({ title: `The ${symOf(a[0])} part is too small to buy anything.`, fix: 'It would spend money for zero tokens, so it was stopped. Increase the amount or that share.' }),
  LegAcquiredNothing: a => ({ title: `The ${symOf(a[0])} purchase came back empty.`, fix: 'Nothing was spent. The pool may not have enough liquidity right now.' }),
  DuplicateAsset: a => ({ title: `${symOf(a[0])} appears twice.`, fix: 'Give each Stock Token one share.' }),
  AssetNotSupported: a => ({ title: `${symOf(a[0])} cannot be used here.`, fix: 'Only Stock Tokens with a reviewed trading route can. Pick another.' }),
  NoLegs: () => ({ title: 'Nothing was chosen.', fix: 'Give at least one Stock Token an amount or a share.' }),
  TooManyLegs: a => ({ title: `${a[0]} Stock Tokens is too many.`, fix: `A basket can take at most ${a[1]} at once.` }),
  NotPositionOwner: () => ({ title: 'Only the owner can do that.', fix: 'If this basket was handed on, control went with it.' }),
  AllocationChangedSinceQuote: () => ({ title: "The owner changed this basket's plan a moment ago.", fix: 'Nothing was spent. The page now shows the new plan: check it, then try again.' }),
  OwnerChangedSinceQuote: a => ({ title: 'This basket changed hands before your addition went through.',
    fix: `You meant it for ${short(a[1])}; it now belongs to ${short(a[2])}. Nothing was spent. The page now shows the new owner; add again only if you mean it for them.` }),
  LengthMismatch: () => ({ title: 'The amounts did not line up with the Stock Tokens.', fix: 'Nothing was moved. Reload and try again.' }),
  NothingReceived: a => ({ title: `No ${symOf(a[0])} arrived.`, fix: 'Nothing was credited. Check the amount and try again.' }),
  PositionDoesNotExist: a => ({ title: `Basket #${a[0]} does not exist any more.`, fix: 'Nothing was spent.' }),
  ZeroAmount: () => ({ title: 'An amount was zero.', fix: 'Enter an amount above zero.' }),
  OutputBelowFloor: a => ({
    title: 'The pool would have given too little, so the purchase was stopped.',
    fix: `One Stock Token would have come to ${tok(a[0])}; the reference price requires at least ${tok(a[1])}. Nothing was spent. ` +
      (D?.priceSource === 'pool'
        ? 'The test pools are small: recent purchases may have moved the price since it was last published, or this amount is too large for them. A smaller amount moves the price less.'
        : 'Try a smaller amount, which moves the price less.'),
  }),
  InputOverspent: () => ({ title: 'The purchase tried to spend more than you allowed.', fix: 'It was cancelled and nothing left your wallet.' }),
  IntentExpired: () => ({ title: 'This took too long and expired.', fix: 'Nothing was spent. Try again.' }),
  FeedStale: () => ({ title: 'There is no current price, so buying is paused.', fix: 'Jayo refuses to buy without a fresh reference price. Moving in Stock Tokens you hold, taking them out and handing baskets on still work.' }),
  FeedAnswerNotPositive: () => ({ title: 'The price feed returned an invalid value.', fix: 'Buying is paused until it recovers. Everything that needs no price still works.' }),
  OraclePausedForCorporateAction: a => ({ title: `${symOf(a[0])} is paused by its issuer.`, fix: 'This happens around dividends or share splits. Taking tokens out still works.' }),
  CorporateActionPending: a => ({ title: `${symOf(a[0])} has a change taking effect shortly.`, fix: 'Jayo does not buy across that moment. Try again afterwards.' }),
  ERC721InsufficientApproval: () => ({ title: 'This basket is not yours to move.', fix: 'Switch to the wallet that owns it.' }),
  ERC20InsufficientBalance: () => ({ title: 'Your wallet does not hold enough.', fix: 'Use a smaller amount. Nothing was moved.' }),
  ERC20InsufficientAllowance: () => ({ title: 'The permission given was too small.', fix: 'Nothing was spent. Try again; the page asks for exactly the amount needed.' }),
};

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
const wasRejected = e => /reject|denied|cancel/i.test(e?.shortMessage || e?.message || '') && !decode(e);

function showError(target, e) {
  if (e?.plain) return showMsg(target, 'warn', e.plain);
  const dec = decode(e);
  const rejected = wasRejected(e);
  const plain = dec && PLAIN[dec.name] ? PLAIN[dec.name](dec.args) : null;
  const raw = (e?.shortMessage || e?.message || String(e)).split('\n').slice(0, 4).join('\n');
  const title = rejected ? 'You cancelled it in your wallet.' : plain ? plain.title : 'That did not go through.';
  const fix = rejected ? 'Nothing was sent.' : plain ? plain.fix : 'Nothing was spent. The technical details are below.';
  const detail = dec ? `${dec.name}(${dec.args.map(String).join(', ')})\n\n${raw}` : raw;
  $(target).innerHTML = `<div class="msg ${rejected ? 'info' : 'error'}"><span class="icon">${rejected ? 'i' : '!'}</span><div class="body">
    <strong>${esc(title)}</strong><br>${esc(fix)}
    ${rejected ? '' : `<details class="tech"><summary>Technical details</summary><pre>${esc(detail)}</pre></details>`}</div></div>`;
  log(`${dec ? dec.name : 'error'}: ${title}`, 'err');
}
function showMsg(target, kind, title, body = '') {
  const icon = { success: '✓', info: 'i', warn: '!', error: '!' }[kind];
  $(target).innerHTML = `<div class="msg ${kind}"><span class="icon">${icon}</span><div class="body"><strong>${esc(title)}</strong>${body ? '<br>' + body : ''}</div></div>`;
}
const clearMsg = (...ids) => ids.forEach(i => { if ($(i)) $(i).innerHTML = ''; });

/** A single-transaction status line (take out, hand on, change plan, wallet). */
function tx(id, state, label, hash = null) {
  const el = $(id);
  el.hidden = false;
  el.dataset.state = state;
  const lab = el.querySelector('.label');
  lab.textContent = label;
  const url = txUrl(hash);
  if (url) {
    const a = document.createElement('a');
    a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = ' · view receipt';
    lab.appendChild(a);
  }
  if (state === 'failed') setTimeout(() => { el.hidden = true; }, 6000);
}

/**
 * The real steps of a multi-transaction action, each with its true state:
 * waiting, active (asking the wallet), pending (sent, with a receipt link),
 * done, skipped or failed. Nothing is marked done before its receipt.
 */
function stepper(id, labels) {
  const el = $(id);
  el.hidden = false;
  el.innerHTML = labels.map((l, i) => `<li data-state="waiting" data-i="${i}"><span class="dot" aria-hidden="true"></span><span>${esc(l)}<small></small></span></li>`).join('');
  const li = i => el.querySelector(`li[data-i="${i}"]`);
  return {
    set(i, state, note = '', hash = null) {
      const item = li(i); if (!item) return;
      item.dataset.state = state;
      const url = txUrl(hash);
      item.querySelector('small').innerHTML = esc(note) + (url ? ` <a href="${url}" target="_blank" rel="noopener noreferrer">receipt</a>` : '');
    },
    failFrom(i, note) {
      this.set(i, 'failed', note);
      for (let j = i + 1; j < labels.length; j++) this.set(j, 'skipped');
    },
  };
}

function busy(btn, on, label) {
  btn.disabled = on;
  if (on) { btn.dataset.text = btn.textContent; btn.innerHTML = `<span class="spin"></span>${esc(label || 'Working…')}`; }
  else if (btn.dataset.text) { btn.textContent = btn.dataset.text; }
}

/** On a public network, every write needs a connected wallet first. */
function needWallet(target) {
  if (connected()) return false;
  showMsg(target, 'info', 'Connect a wallet first.', 'Looking around needs no wallet; changing anything does. <button class="btn btn-primary btn-sm" type="button" data-connect>Connect wallet</button>');
  $(target).querySelector('[data-connect]')?.addEventListener('click', connectWallet);
  return true;
}

// ------------------------------------------------------------------ writes ---
//
// Every write SIMULATES first, from the sending account, so a revert comes back
// with its data and decode() can name it. The simulated request is what is sent.
async function send(params) {
  if (!connected()) throw new Error('Connect a wallet first.');
  const { request } = await pub.simulateContract({ ...params, account: account().address });
  const { account: _ignored, ...rest } = request;
  return wallet().writeContract({ ...rest, account: wallet().account });
}

/// Deadlines come from CHAIN time: a visitor's clock can simply be wrong.
async function deadline() {
  if (isLocal) await LOCAL.freshBlock();
  return (await pub.getBlock()).timestamp + 3600n;
}

/// Approve exactly `amount` of `token` for the current basket if the standing
/// permission is smaller. Never an open-ended allowance. Checks the balance
/// first: a permission for tokens the wallet does not have would cost a
/// transaction and then fail anyway. Returns false when no approval was needed.
async function ensureAllowance(token, amount, steps, i) {
  const who = account().address;
  const balance = await pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'balanceOf', args: [who] });
  if (balance < amount) {
    const isStable = token.toLowerCase() === D.usdg.toLowerCase();
    throw Object.assign(new Error('insufficient balance'), {
      plain: isStable
        ? `You have ${usdg(balance)} ${stableSym()}, less than ${usdg(amount)}. Get more test rUSDG from your wallet panel (top right), or use a smaller amount. Nothing was sent.`
        : `You have ${tok(balance)} ${symOf(token)}, less than ${tok(amount)}. Use a smaller amount. Nothing was sent.`,
    });
  }
  const allowance = await pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'allowance', args: [who, D.basket] });
  if (allowance >= amount) { steps.set(i, 'skipped', 'already allowed'); return false; }
  steps.set(i, 'active', 'confirm in your wallet');
  const h = await send({ address: token, abi: ERC20_ABI, functionName: 'approve', args: [D.basket, amount] });
  steps.set(i, 'pending', 'waiting for the chain', h);
  await pub.waitForTransactionReceipt({ hash: h });
  steps.set(i, 'done', 'allowed', h);
  log(`allowed Jayo to move exactly ${token.toLowerCase() === D.usdg.toLowerCase() ? usdg(amount) + ' ' + stableSym() : tok(amount) + ' ' + symOf(token)}`, 'ok', h);
  return true;
}

/// Before asking for any permission, make sure the basket still has the owner
/// and plan the page showed. The contract enforces this at the moment the
/// addition is mined; checking here as well means a basket that changed hands
/// while the page was open costs the visitor nothing, not even an approval.
async function stillAsShown(b) {
  const [owner, version] = await Promise.all([
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'ownerOf', args: [b.id] }),
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'allocationVersion', args: [b.id] }),
  ]);
  if (owner.toLowerCase() !== b.owner.toLowerCase()) {
    throw Object.assign(new Error('owner changed'), { errorName: 'OwnerChangedSinceQuote', args: [b.id, b.owner, owner] });
  }
  if (version !== b.version) {
    throw Object.assign(new Error('plan changed'), { errorName: 'AllocationChangedSinceQuote', args: [b.id, b.version, version] });
  }
}

/// Send the main transaction of an action through its step: wallet, pending, done.
async function sendStep(steps, i, params) {
  steps.set(i, 'active', 'confirm in your wallet');
  const hash = await send(params);
  steps.set(i, 'pending', 'waiting for the chain', hash);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('The transaction was mined but reverted.');
  steps.set(i, 'done', 'confirmed', hash);
  return { hash, receipt };
}

function parseAmount(id, decimals = 6) {
  const raw = String($(id).value || '').replace(/,/g, '').trim();
  const re = decimals === 6 ? /^\d+(\.\d{0,6})?$/ : /^\d+(\.\d{0,18})?$/;
  if (!re.test(raw)) throw Object.assign(new Error('bad amount'), { plain: 'Enter an amount like 20 or 12.5.' });
  const v = parseUnits(raw, decimals);
  if (v === 0n) throw Object.assign(new Error('zero'), { plain: 'Enter an amount above zero.' });
  return v;
}

// ------------------------------------------------------------------ boot ----

const REPORT = '/deployment.json';
const HOME_TITLE = document.title;

async function loadDeployment() {
  try {
    const r = await fetch(REPORT, { cache: 'no-store' });
    if (r.ok) return await r.json();
  } catch { /* handled by the caller */ }
  return null;
}

async function connect() {
  if (D.chainId === 31337 && !LOCAL) return false;
  isLocal = D.chainId === 31337;
  chain = isLocal ? LOCAL.chain : {
    id: D.chainId,
    name: 'Robinhood Chain testnet',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [D.rpcUrl] } },
    ...(D.multicall3 ? { contracts: { multicall3: { address: D.multicall3 } } } : {}),
  };
  pub = createPublicClient({ chain, transport: http(isLocal ? LOCAL.rpc : D.rpcUrl), batch: { multicall: !isLocal && !!D.multicall3 } });
  if (isLocal) return true;

  /* @local-only-start */
  // Served by `node app/serve.mjs --testnet-signer` only: a local test signer
  // holding two demo user wallets, which signs nothing but the decoded journey.
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
    const useSigner = addr => { injectedAddress = addr; injected = createWalletClient({ account: addr, chain, transport: custom(provider) }); };
    useSigner(D.localSigners[0]);
    $('signerSel').innerHTML = D.localSigners.map((a, i) => `<option value="${a}">Test wallet ${'AB'[i] || i + 1} ${short(a)}</option>`).join('');
    $('signerPick').hidden = false;
    $('signerSel').addEventListener('change', async () => { useSigner($('signerSel').value); await afterAccountChange(); });
    return true;
  }
  /* @local-only-end */

  $('btnConnect').hidden = false;
  $('btnConnect').addEventListener('click', connectWallet);
  return true;
}

/// The visitor's own wallet: request accounts, then make sure it is on this chain.
async function connectWallet() {
  if (!window.ethereum) {
    showMsg('walletMsg', 'warn', 'No browser wallet found.', 'Install a wallet extension that supports custom networks (MetaMask, Rabby and others), then reload this page.');
    $('walletPanel').hidden = false;
    return;
  }
  try {
    const [addr] = await window.ethereum.request({ method: 'eth_requestAccounts' });
    const hex = '0x' + D.chainId.toString(16);
    const currentChain = await window.ethereum.request({ method: 'eth_chainId' });
    if (parseInt(currentChain, 16) !== D.chainId) {
      try {
        await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] });
      } catch {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{ chainId: hex, chainName: 'Robinhood Chain Testnet', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
            rpcUrls: [D.rpcUrl], blockExplorerUrls: D.explorer ? [D.explorer] : undefined }],
        });
      }
    }
    injectedAddress = getAddress(addr);
    injected = createWalletClient({ account: injectedAddress, chain, transport: custom(window.ethereum) });
    if (!window.__jayoWired && window.ethereum.on) {
      // The simplest correct response to a wallet changing account or network: start over.
      window.ethereum.on('accountsChanged', () => location.reload());
      window.ethereum.on('chainChanged', () => location.reload());
      window.__jayoWired = true;
    }
    $('btnConnect').hidden = true;
    log(`wallet connected: ${short(injectedAddress)}`, 'ok');
    await afterAccountChange();
  } catch (e) {
    $('walletPanel').hidden = false;
    showError('walletMsg', e);
  }
}

async function afterAccountChange() {
  await refreshWallet(true);
  await loadBaskets();
  await renderKindRows();
  await route();
}

/// The basket contracts this deployment knows, oldest first. Ids never overlap:
/// each version starts above the last id the one before could reach.
async function discoverContracts() {
  const first3 = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'firstTokenId' });
  const list = [];
  let first2 = first3;
  if (D.legacyBasket2) {
    first2 = await pub.readContract({ address: D.legacyBasket2, abi: LEGACY2_ABI, functionName: 'firstTokenId' });
    list.push({ version: 2, address: D.legacyBasket2, abi: LEGACY2_ABI, first: first2, end: first3, legacy: true,
      deployBlock: D.legacyDeployBlock2, counters: true, enumerate: 'next' });
  }
  if (D.legacyBasket) {
    list.unshift({ version: 1, address: D.legacyBasket, abi: LEGACY1_ABI, first: 1n, end: first2, legacy: true,
      deployBlock: D.legacyDeployBlock, counters: false, enumerate: 'probe' });
  }
  list.push({ version: 3, address: D.basket, abi: BASKET_ABI, first: first3, end: null, legacy: false,
    deployBlock: D.deployBlock, counters: true, enumerate: 'next' });
  return list;
}
const contractFor = id => CONTRACTS.find(c => id >= c.first && (c.end === null || id < c.end)) || null;

async function boot() {
  D = await loadDeployment();
  if (!D) { $('heroCard').innerHTML = '<div class="skeleton">No deployment found. Run ./scripts/run-demo.sh.</div>'; return; }
  if (!(await connect())) { $('heroCard').innerHTML = '<div class="skeleton">This build does not include the local demo.</div>'; return; }

  $('netPill').textContent = isLocal ? 'Local demo · mock assets' : 'Testnet · no real value';
  if (isLocal) $('footNote').innerHTML = '<strong>Jayo</strong> local demo: every asset, pool and price here is a mock on a local chain, with no value.';
  /* @local-only-start */
  if (isLocal) $('demoPanel').hidden = false;
  /* @local-only-end */

  const stocks = D.stocks || [D.aapl, D.nvda].filter(Boolean);
  const names = await Promise.all([...stocks, D.usdg].map(async a => {
    const [symbol, name] = await Promise.all([
      pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'symbol' }),
      pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'name' }),
    ]);
    return [a, symbol, name];
  }));
  names.forEach(([a, symbol, name], i) => {
    META[a.toLowerCase()] = { symbol, name: name.replace(' [MOCK]', '').replace(/\s+Robinhood Token$/i, ''), color: PALETTE[i % PALETTE.length] };
  });
  ASSETS = stocks;
  CONTRACTS = await discoverContracts();
  minLeg = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'minLegInput' });
  document.querySelectorAll('[data-unit], #fundUnit').forEach(el => { el.textContent = stableSym(); });
  if (D.suggestedFund) $('fund').value = formatUnits(BigInt(D.suggestedFund), 6);
  $('sizeGuide').hidden = D.priceSource !== 'pool';

  createMix = mixEditor('createMix', ASSETS.map((a, i) => ({ asset: a, pct: i === 0 ? 60 : Math.floor(40 / (ASSETS.length - 1)) })), () => {
    ribbon('createRibbon', createMix.rows().map(r => ({ asset: r.asset, weight: r.pct })), { legend: false });
    clearMsg('createMsg'); $('createQuote').innerHTML = '<p class="muted">Check what you would get before you buy.</p>';
    applyBuyingState();
  });
  ribbon('createRibbon', createMix.rows().map(r => ({ asset: r.asset, weight: r.pct })), { legend: false });
  kindMix = mixEditor('kindMix', ASSETS.map((a, i) => ({ asset: a, pct: i === 0 ? 60 : Math.floor(40 / (ASSETS.length - 1)) })), () => { kindPlanTouched = true; });

  describePrices();
  await renderPrices();
  setInterval(() => renderPrices().catch(() => {}), 30_000);
  await refreshWallet(false);
  await loadBaskets();
  await renderKindRows();
  await route();
  window.addEventListener('popstate', () => route());
  log(isLocal ? 'reading the local demo chain (mock assets)' : 'reading Robinhood Chain testnet (test assets with no value)', 'ok');
}

// ---------------------------------------------------------------- routing ---

async function route() {
  const id = new URLSearchParams(location.search).get('basket');
  if (id && /^\d{1,9}$/.test(id)) {
    $('home').hidden = true;
    $('basketView').hidden = false;
    await showBasket(BigInt(id));
  } else {
    $('basketView').hidden = true;
    $('home').hidden = false;
    current = null;
    document.title = HOME_TITLE;
    renderHome();
  }
}

function go(href) {
  history.pushState({}, '', href);
  route().then(() => window.scrollTo({ top: 0, behavior: 'auto' }));
}

// Same-page links (cards, "All baskets", history) route without a reload.
document.addEventListener('click', ev => {
  const a = ev.target.closest('a[data-route]');
  if (!a || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button !== 0) return;
  ev.preventDefault();
  go(a.getAttribute('href'));
});
$('backLink').dataset.route = '1';

// Segmented switches (start mode, what to add): plain tabs over two panels.
function wireModes(groupId, onChange) {
  const group = $(groupId);
  group.addEventListener('click', ev => {
    const t = ev.target.closest('[role=tab]');
    if (!t) return;
    for (const b of group.querySelectorAll('[role=tab]')) {
      const on = b === t;
      b.setAttribute('aria-selected', String(on));
      $(b.getAttribute('aria-controls')).hidden = !on;
    }
    onChange?.(t.id);
  });
}
wireModes('startModes');
wireModes('addModes');

// ------------------------------------------------------------------ prices ---

async function renderPrices() {
  const assets = [...ASSETS, D.usdg];
  const [blk, cfgs] = await Promise.all([
    pub.getBlock(),
    Promise.all(assets.map((a, i) => pub.readContract({
      address: D.policy, abi: POLICY_ABI, functionName: i < ASSETS.length ? 'stockTokenConfig' : 'quoteAssetConfig', args: [a],
    }))),
  ]);
  const rounds = await Promise.all(cfgs.map(c => pub.readContract({ address: c.feed, abi: FEED_ABI, functionName: 'latestRoundData' })));
  const now = Number(blk.timestamp);
  PRICES = {};
  let oldest = 0; let minLeft = Infinity;
  assets.forEach((a, i) => {
    const updatedAt = Number(rounds[i][3]);
    const maxStale = Number(cfgs[i].maxStaleness);
    PRICES[a.toLowerCase()] = { price8: rounds[i][1], updatedAt, maxStale };
    oldest = Math.max(oldest, now - updatedAt);
    minLeft = Math.min(minLeft, maxStale - (now - updatedAt));
  });
  const wasOpen = buyingOpen;
  buyingOpen = minLeft > 0;

  const chip = $('priceChip');
  chip.dataset.state = buyingOpen ? 'open' : 'paused';
  $('priceChipText').textContent = buyingOpen ? `Buying open · prices ${ago(oldest)} old` : 'Buying paused · prices expired';

  const stateHtml = buyingOpen
    ? `<p class="buy-state"><span class="dot"></span><span>Checked against reference prices published ${esc(ago(oldest))} ago.
        ${D.priceSource === 'pool' ? 'On this testnet they are read from the same pools. <a href="#aboutPrices" data-about>Why that matters</a>' : ''}</span></p>`
    : `<div class="msg warn"><span class="icon">!</span><div class="body"><strong>Buying is paused.</strong><br>
        The reference prices are ${esc(ago(oldest))} old and Jayo refuses to buy without a fresh one.
        ${D.priceSource === 'pool' ? 'A scheduled keeper republishes them from the pools every 20 minutes; if it has stopped, buying stays paused until it runs again.' : 'Use "Refresh prices" in the demo controls.'}
        <strong>Moving in Stock Tokens you hold, taking them out and handing baskets on still work.</strong></div></div>`;
  for (const id of ['createBuyState', 'addBuyState', 'copyBuyState']) $(id).innerHTML = stateHtml;
  document.querySelectorAll('[data-about]').forEach(a => a.addEventListener('click', openAbout));
  applyBuyingState();
  if (buyingOpen !== wasOpen && current) schedulePreview();
}

function openAbout(ev) {
  ev?.preventDefault();
  if ($('home').hidden) go('./');
  setTimeout(() => { $('aboutPrices').open = true; $('aboutPrices').scrollIntoView({ block: 'start' }); }, 50);
}
$('priceChip').addEventListener('click', openAbout);

function applyBuyingState() {
  const ok = createMix?.valid();
  $('btnCreate').disabled = !buyingOpen || !ok;
  $('btnQuote').disabled = !buyingOpen || !ok;
  if (current) {
    $('btnAdd').disabled = !buyingOpen || current.legacy || !current.exists;
    $('btnCopy').disabled = !buyingOpen || !(current.plan?.length);
  }
}

function describePrices() {
  const floorPct = D.maxShortfallBps ? `${D.maxShortfallBps / 100}%` : 'a fixed margin';
  const life = D.feedHeartbeat ? ago(D.feedHeartbeat) : 'an hour';
  $('aboutPricesBody').innerHTML = D.priceSource === 'pool' ? `
    <p><strong>Where they come from.</strong> Chainlink publishes no prices on this test network, so Jayo's testnet feeds copy the
      current price of the same Uniswap pools it buys in. A scheduled keeper republishes them every 20 minutes with a dedicated key
      ${D.updater ? `(<a href="${esc(D.explorer)}/address/${esc(D.updater)}" target="_blank" rel="noopener noreferrer">${esc(short(D.updater))}</a>)` : ''}
      that can do nothing except publish within the feeds' own limits: at most one update every ${D.feedMinInterval ? ago(D.feedMinInterval) : '15 min'},
      no single move over 10%, and no more than 25% in a day. Each price expires after ${esc(life)}; after that, buying pauses.</p>
    <p><strong>What they protect.</strong> Each Stock Token you buy must arrive within ${esc(floorPct)} of its reference price. The pool's
      fee and the price movement your own purchase causes both count against that, and a purchase that would fall short is refused
      before any money moves.</p>
    <p><strong>What they cannot protect.</strong> Because the reference comes from the pool itself, it cannot tell you whether the pool
      is fairly priced. Today the testnet TSLA pool trades about 25% below Chainlink's mainnet TSLA price, and a purchase here would
      still go through. Only an independent price can catch that. The project's mainnet-fork test checks every purchase against
      Chainlink's independent mainnet feeds, and refuses the ones that fall short.</p>
    <p>Moving in Stock Tokens you hold, taking them out and handing baskets on never use these prices, so they work even when every
      price has expired.</p>`
    : `<p>These are demo prices on the local chain; only the local deployer can change them. Each expires after ${esc(life)}, and buying is
      refused once any has. Each Stock Token you buy must arrive within ${esc(floorPct)} of them. Taking tokens out never needs a price.</p>`;
}

// ------------------------------------------------------------------ wallet ---

let pendingRevoke = null;

async function refreshWallet(openIfNeeded) {
  if (!connected()) { $('walletChip').hidden = true; return; }
  const addr = account().address;
  const allowanceOf = (token, spender) => pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'allowance', args: [addr, spender] });
  const [eth, bal] = await Promise.all([
    pub.getBalance({ address: addr }),
    pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }),
  ]);
  // A standing permission is shown so it can be removed: stablecoin permissions
  // to any version, and Stock Token permissions left by an in-kind addition that
  // did not complete. The current page only ever asks for exact amounts.
  const checks = [];
  for (const c of CONTRACTS) checks.push({ token: D.usdg, spender: c.address, label: c.legacy ? `the version-${c.version} basket contract` : 'the basket contract' });
  for (const s of ASSETS) checks.push({ token: s, spender: D.basket, label: 'the basket contract' });
  const amounts = await Promise.all(checks.map(k => allowanceOf(k.token, k.spender)));
  const left = checks.map((k, i) => ({ ...k, amount: amounts[i] })).filter(k => k.amount > 0n);

  const ethOk = isLocal || eth >= 20_000_000_000_000n;
  const usdOk = bal >= 10_000000n;
  $('gasBal').textContent = isLocal ? '' : `You have ${Number(formatUnits(eth, 18)).toLocaleString(NUM, { maximumFractionDigits: 6 })} test ETH.`;
  $('ckGas').dataset.done = String(ethOk);
  $('ckGas').hidden = isLocal;
  $('usdBal').textContent = `You have ${usdg(bal)} ${stableSym()}.`;
  $('ckUsd').dataset.done = String(usdOk);

  pendingRevoke = left[0] || null;
  $('ckAllow').hidden = !pendingRevoke;
  if (pendingRevoke) {
    const isStable = pendingRevoke.token.toLowerCase() === D.usdg.toLowerCase();
    const amt = pendingRevoke.amount >= 2n ** 128n ? 'an unlimited amount of' : `up to ${isStable ? usdg(pendingRevoke.amount) : tok(pendingRevoke.amount)}`;
    $('allowText').textContent = `${pendingRevoke.label[0].toUpperCase()}${pendingRevoke.label.slice(1)} may still take ${amt} ${isStable ? stableSym() : symOf(pendingRevoke.token)} from this wallet. `
      + 'It can only use it in an action you sign, but you can set it to zero now.';
    $('ckAllow').dataset.done = 'false';
  }

  const attention = !ethOk || !usdOk || !!pendingRevoke;
  const chip = $('walletChip');
  chip.hidden = false;
  chip.innerHTML = `<span class="avatar" aria-hidden="true"></span>${isLocal ? esc(LOCAL.label()) : addrHtml(addr)}`;
  chip.dataset.attention = String(attention);
  chip.setAttribute('aria-label', `Your wallet ${addr}${attention ? ', something needs attention' : ''}`);
  if (openIfNeeded && attention) { $('walletPanel').hidden = false; chip.setAttribute('aria-expanded', 'true'); }
}

$('walletChip').addEventListener('click', () => {
  const open = $('walletPanel').hidden;
  $('walletPanel').hidden = !open;
  $('walletChip').setAttribute('aria-expanded', String(open));
});

$('btnMint').addEventListener('click', async () => {
  clearMsg('walletMsg');
  if (needWallet('walletMsg')) return;
  const btn = $('btnMint'); busy(btn, true, 'Minting…');
  try {
    tx('walletTx', 'signing', 'Confirm in your wallet…');
    const hash = await send({ address: D.usdg, abi: ERC20_ABI, functionName: 'mint', args: [account().address, 100_000000n] });
    tx('walletTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    tx('walletTx', 'confirmed', `You have 100 more test ${stableSym()}`, hash);
    log(`got 100 test ${stableSym()}`, 'ok', hash);
    await refreshWallet(false);
  } catch (e) { tx('walletTx', 'failed', 'Nothing was minted'); showError('walletMsg', e); }
  finally { busy(btn, false); }
});

$('btnRevoke').addEventListener('click', async () => {
  clearMsg('walletMsg');
  if (needWallet('walletMsg') || !pendingRevoke) return;
  const { token, spender, label } = pendingRevoke;
  const btn = $('btnRevoke'); busy(btn, true, 'Removing…');
  try {
    tx('walletTx', 'signing', 'Confirm in your wallet: this sets the permission to zero…');
    const hash = await send({ address: token, abi: ERC20_ABI, functionName: 'approve', args: [spender, 0n] });
    tx('walletTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    const left = await pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'allowance', args: [account().address, spender] });
    tx('walletTx', left === 0n ? 'confirmed' : 'failed', left === 0n ? `Removed: ${label} can take 0 from this wallet` : 'Still allowed', hash);
    log(`removed a permission for ${label}`, left === 0n ? 'ok' : 'err', hash);
    await refreshWallet(false);
  } catch (e) { tx('walletTx', 'failed', 'The permission was not changed'); showError('walletMsg', e); }
  finally { busy(btn, false); }
});

// ----------------------------------------------------------------- baskets ---

async function readMany(calls) {
  if (!calls.length) return [];
  if (!isLocal && D.multicall3) {
    return (await pub.multicall({ allowFailure: true, contracts: calls })).map(r => (r.status === 'success' ? r.result : null));
  }
  return Promise.all(calls.map(c => pub.readContract(c).catch(() => null)));
}

/// Every live basket of every version, with holdings and plan.
async function loadBaskets() {
  const out = [];
  for (const c of CONTRACTS) {
    let ids = [];
    if (c.enumerate === 'next') {
      const next = await pub.readContract({ address: c.address, abi: c.abi, functionName: 'nextTokenId' });
      for (let i = c.first; i < next; i++) ids.push(i);
    } else {
      // Version 1 publishes no id counter: probe in batches until one is empty.
      for (let s = c.first; s < c.end; s += 20n) {
        const batch = Array.from({ length: 20 }, (_, i) => s + BigInt(i)).filter(i => i < c.end);
        const o = await readMany(batch.map(id => ({ address: c.address, abi: c.abi, functionName: 'ownerOf', args: [id] })));
        if (!o.some(Boolean)) break;
        ids.push(...batch);
      }
    }
    const owners = await readMany(ids.map(id => ({ address: c.address, abi: c.abi, functionName: 'ownerOf', args: [id] })));
    const live = ids.filter((_, i) => owners[i]);
    const liveOwners = owners.filter(Boolean);
    const per = c.counters ? ['holdingsOf', 'allocationOf', 'fundingCount', 'totalFunded', 'allocationVersion'] : ['holdingsOf', 'allocationOf'];
    const data = await readMany(live.flatMap(id => per.map(f => ({ address: c.address, abi: c.abi, functionName: f, args: [id] }))));
    live.forEach((id, i) => {
      const [h, plan, count = null, funded = null, version = null] = data.slice(i * per.length, (i + 1) * per.length);
      out.push({ id, c, legacy: c.legacy, exists: true, owner: liveOwners[i], assets: h[0], amounts: h[1], plan,
        count: count === null ? null : Number(count), funded, version });
    });
  }
  baskets = out;
}

const totalValue = b => b.assets.reduce((s, a, i) => s + valueOf(a, b.amounts[i]), 0);

/** Render a ribbon. parts: [{ asset, weight }] - weight in any unit, shares are relative. */
function ribbon(hostId, parts, { legend = true } = {}) {
  const host = $(hostId);
  const total = parts.reduce((s, p) => s + p.weight, 0);
  host.classList.remove('empty');
  if (!total) { host.innerHTML = ''; host.classList.add('empty'); return; }
  const segs = parts.filter(p => p.weight > 0);
  // Keep existing segments so a change animates from the old width to the new.
  const existing = [...host.querySelectorAll('.seg')];
  if (existing.length !== segs.length || existing.some((s, i) => s.dataset.a !== segs[i].asset.toLowerCase())) {
    host.innerHTML = segs.map(p => `<span class="seg" style="--c:${colorOf(p.asset)}" data-a="${p.asset.toLowerCase()}"></span>`).join('');
  }
  const els = [...host.querySelectorAll('.seg')];
  els.forEach((s, i) => { s.title = `${symOf(segs[i].asset)} ${(100 * segs[i].weight / total).toFixed(0)}%`; s.dataset.w = (100 * segs[i].weight / total).toFixed(3); });
  requestAnimationFrame(() => els.forEach(s => { s.style.width = `calc(${s.dataset.w}% - 4px)`; }));
  if (legend) {
    let lg = host.nextElementSibling;
    if (!lg || !lg.classList.contains('legend')) { lg = document.createElement('div'); lg.className = 'legend'; host.after(lg); }
    lg.innerHTML = segs.map(p => `<span style="--c:${colorOf(p.asset)}"><i></i>${esc(symOf(p.asset))} ${(100 * p.weight / total).toFixed(0)}%</span>`).join('');
  }
}
const holdingParts = (assets, amounts) => assets.map((a, i) => ({ asset: a, weight: valueOf(a, amounts[i]) || Number(formatUnits(amounts[i], 18)) }));

function cardHtml(b, { hero = false } = {}) {
  const mine = isMine(b);
  const holds = b.assets.map((a, i) => `<b>${esc(symOf(a))}</b> ${tok(b.amounts[i])}`).join(' · ') || 'Holds nothing';
  const val = totalValue(b);
  const tags = [b.legacy ? `<span class="tag tag-v1">Version ${b.c.version} · withdraw only</span>` : '',
    !b.legacy && b.count > 1 ? `<span class="tag tag-gift">Added to ${b.count - 1}×</span>` : ''].join(' ');
  const rid = `rb-${hero ? 'hero-' : ''}${b.id}`;
  return `<a class="bcard" href="${basketUrl(b)}" data-route="1" aria-label="Basket ${b.id}${mine ? ', yours' : ''}">
    ${hero ? `<p class="eyebrow">${b.legacy ? 'An earlier basket' : b.count > 1 ? 'A basket people have added to' : 'A basket on this testnet'}</p>` : ''}
    <div class="bcard-top"><span class="bcard-id">#${b.id}</span>
      <span class="bcard-owner ${mine ? 'yours' : ''}">${mine ? 'Yours' : `Owned by ${addrHtml(b.owner)}`}</span></div>
    <div class="ribbon" id="${rid}"></div>
    <p class="holds">${holds}</p>
    <div class="bcard-foot"><span>${val ? `≈ ${usd(val)} at reference prices` : ''}</span><span>${tags}</span></div>
  </a>`;
}
function paintCardRibbons(list, hero = false) {
  for (const b of list) {
    const rid = `rb-${hero ? 'hero-' : ''}${b.id}`;
    if ($(rid)) ribbon(rid, holdingParts(b.assets, b.amounts), { legend: false });
  }
}

function renderHome() {
  const withHoldings = baskets.filter(b => b.assets.length);
  // The hero shows a real basket: the current-version one added to most, else the largest.
  const featured = [...withHoldings].sort((x, y) => (Number(x.legacy) - Number(y.legacy)) || ((y.count || 0) - (x.count || 0)) || (totalValue(y) - totalValue(x)))[0];
  $('heroCard').innerHTML = featured ? cardHtml(featured, { hero: true }) : '<div class="empty-state"><p><strong>No baskets yet.</strong></p><p>Start the first one below.</p></div>';
  if (featured) paintCardRibbons([featured], true);

  const mine = connected() ? baskets.filter(isMine) : [];
  $('mine').hidden = !connected();
  $('mineCount').textContent = mine.length ? `${mine.length} basket${mine.length > 1 ? 's' : ''}` : '';
  $('myCards').innerHTML = mine.length
    ? mine.map(b => cardHtml(b)).join('')
    : `<div class="empty-state"><p><strong>You do not own a basket yet.</strong></p><p>Start one below with rUSDG or with Stock Tokens you hold, or open someone's basket and copy its plan.</p></div>`;
  paintCardRibbons(mine);

  const others = baskets.filter(b => !isMine(b)).sort((x, y) => (Number(x.legacy) - Number(y.legacy)) || Number(y.id - x.id));
  $('allCards').innerHTML = others.length ? others.map(b => cardHtml(b)).join('') : '<div class="empty-state"><p>No other baskets yet.</p></div>';
  paintCardRibbons(others);
}

// ------------------------------------------------------------- mix editor ---

let createMix = null;
let planMix = null;
let kindMix = null;
let kindPlanTouched = false;

/// Rows of Stock Token + share, each a slider and a number, with a live total.
function mixEditor(hostId, initial, onChange) {
  let rows = initial.map(r => ({ ...r }));
  const host = $(hostId);
  const render = () => {
    host.innerHTML = rows.map((r, i) => {
      const m = META[r.asset.toLowerCase()];
      return `<div class="mix-row" style="--c:${m.color}">
        <div class="asset"><span class="swatch"></span><span><span class="sym">${esc(m.symbol)}</span><span class="name">${esc(m.name)}</span></span></div>
        <input type="range" min="0" max="100" step="5" value="${r.pct}" data-i="${i}" aria-label="${esc(m.symbol)} share">
        <span class="pct"><input type="number" min="0" max="100" step="1" value="${r.pct}" data-i="${i}" aria-label="${esc(m.symbol)} share, percent">%</span>
      </div>`;
    }).join('') + '<p class="mix-total" aria-live="polite"></p>';
    host.querySelectorAll('input').forEach(inp => inp.addEventListener('input', ev => {
      const i = Number(ev.target.dataset.i);
      rows[i].pct = Math.max(0, Math.min(100, Math.round(Number(ev.target.value) || 0)));
      // Two Stock Tokens: moving one moves the other, so the mix always adds up.
      if (rows.length === 2) rows[1 - i].pct = 100 - rows[i].pct;
      host.querySelectorAll('input').forEach(x => { if (x !== ev.target) x.value = rows[Number(x.dataset.i)].pct; });
      total(); onChange?.();
    }));
    total();
  };
  const total = () => {
    const t = rows.reduce((s, r) => s + r.pct, 0);
    const el = host.querySelector('.mix-total');
    el.textContent = t === 100 ? 'Adds up to 100%' : `Adds up to ${t}%: it needs to be exactly 100%`;
    el.className = `mix-total ${t === 100 ? 'good' : 'bad'}`;
  };
  render();
  return {
    rows: () => rows,
    valid: () => rows.reduce((s, r) => s + r.pct, 0) === 100 && rows.some(r => r.pct > 0),
    allocation: () => rows.filter(r => r.pct > 0).map(r => ({ asset: r.asset, weightBps: r.pct * 100 })),
    set: next => { rows = next.map(r => ({ ...r })); render(); },
  };
}

// ------------------------------------------------------------------ create ---

function quoteHtml(amount, assets, ins, refs, floors, unspent, recipient = null) {
  const lines = assets.map((a, i) => `<dt>${esc(symOf(a))}: ${usdg(ins[i])} ${esc(stableSym())}</dt>
    <dd>about ${tok(refs[i])}<span class="least">at least ${tok(floors[i])}</span></dd>`).join('');
  return `<dl><dt>You pay</dt><dd>${usdg(amount)} ${esc(stableSym())}</dd><div class="sep"></div>${lines}
    <div class="sep"></div><dt>Returned to you</dt><dd>${usdg(unspent)} ${esc(stableSym())}</dd>
    ${recipient ? `<dt>Goes to</dt><dd>${recipient}</dd>` : ''}
    <p class="note">"About" is what the reference price says you should get. "At least" is the least Jayo accepts: if the pool gives
      less, the whole purchase is cancelled and you keep your money.</p></dl>`;
}

$('fund').addEventListener('input', () => { clearMsg('createMsg'); $('createQuote').innerHTML = '<p class="muted">Check what you would get before you buy.</p>'; });

$('btnQuote').addEventListener('click', async () => {
  clearMsg('createMsg');
  const btn = $('btnQuote'); busy(btn, true, 'Checking…');
  try {
    const amount = parseAmount('fund');
    const alloc = createMix.allocation();
    const [ins, refs, floors, unspent] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'previewCreate', args: [alloc, amount] });
    $('createQuote').innerHTML = quoteHtml(amount, alloc.map(x => x.asset), ins, refs, floors, unspent);
  } catch (e) { showError('createMsg', e); }
  finally { busy(btn, false); applyBuyingState(); }
});

$('btnCreate').addEventListener('click', async () => {
  clearMsg('createMsg');
  if (needWallet('createMsg')) return;
  const btn = $('btnCreate'); busy(btn, true, 'Creating…');
  const steps = stepper('createSteps', [`Allow exactly this much ${stableSym()}`, 'Buy the Stock Tokens into a new basket']);
  try {
    const amount = parseAmount('fund');
    await ensureAllowance(D.usdg, amount, steps, 0);
    const { hash, receipt } = await sendStep(steps, 1, { address: D.basket, abi: BASKET_ABI, functionName: 'create', args: [createMix.allocation(), amount, await deadline()] });
    const made = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'BasketCreated' })[0];
    log(`created basket #${made?.args.tokenId}`, 'ok', hash);
    await refreshWallet(false); await loadBaskets();
    if (made) { freshHashes.add(hash); go(`?basket=${made.args.tokenId}`); }
  } catch (e) {
    steps.failFrom([...$('createSteps').children].findIndex(li => ['active', 'pending', 'waiting'].includes(li.dataset.state)), wasRejected(e) ? 'cancelled in your wallet' : 'not done');
    showError('createMsg', e);
  } finally { busy(btn, false); applyBuyingState(); }
});

// ---------------------------------------------------------------- in kind ---
//
// Starting or adding with Stock Tokens already held. Each row shows what the
// wallet holds; the amounts are moved in as they are - nothing is priced,
// bought or sold - and the contract credits what actually arrives.

let heldBalances = {};

async function readHeld() {
  heldBalances = {};
  if (!connected()) return;
  const bals = await Promise.all(ASSETS.map(a => pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'balanceOf', args: [account().address] })));
  ASSETS.forEach((a, i) => { heldBalances[a.toLowerCase()] = bals[i]; });
}

function kindRowsHtml(prefix) {
  return ASSETS.map(a => {
    const m = META[a.toLowerCase()];
    const have = heldBalances[a.toLowerCase()] ?? 0n;
    return `<div class="kind-row" style="--c:${m.color}">
      <div class="asset"><span class="swatch"></span><span><span class="sym">${esc(m.symbol)}</span><span class="have">You hold ${tok(have)}</span></span></div>
      <input id="${prefix}-${a}" inputmode="decimal" placeholder="0" autocomplete="off" aria-label="${esc(m.symbol)} to move in" ${have === 0n ? 'disabled' : ''}>
      <button class="max" type="button" data-max="${prefix}-${a}" data-amt="${formatUnits(have, 18)}" ${have === 0n ? 'disabled' : ''}>All</button>
    </div>`;
  }).join('');
}

async function renderKindRows() {
  await readHeld();
  const none = connected() && ASSETS.every(a => (heldBalances[a.toLowerCase()] ?? 0n) === 0n);
  const holderNote = none ? `<p class="muted">This wallet holds none of these Stock Tokens. Test Stock Tokens come from the testnet faucets.</p>` : '';
  $('kindRows').innerHTML = connected() ? kindRowsHtml('ks') + holderNote : '<p class="muted">Connect a wallet to see which Stock Tokens it holds.</p>';
  $('addKindRows').innerHTML = connected() ? kindRowsHtml('ka') + holderNote : '<p class="muted">Connect a wallet to see which Stock Tokens it holds.</p>';
  document.querySelectorAll('[data-max]').forEach(b => b.addEventListener('click', () => {
    const inp = $(b.dataset.max); inp.value = b.dataset.amt; inp.dispatchEvent(new Event('input', { bubbles: true }));
  }));
  document.querySelectorAll('#kindRows input').forEach(inp => inp.addEventListener('input', suggestKindPlan));
}

/// The chosen in-kind amounts, as [assets[], amounts[]], or a plain error.
function readKind(prefix) {
  const assets = [], amounts = [];
  for (const a of ASSETS) {
    const raw = String($(`${prefix}-${a}`)?.value || '').replace(/,/g, '').trim();
    if (!raw) continue;
    if (!/^\d+(\.\d{0,18})?$/.test(raw)) throw Object.assign(new Error('bad'), { plain: `Enter the ${symOf(a)} amount like 1 or 0.25.` });
    const v = parseUnits(raw, 18);
    if (v === 0n) continue;
    if (v > (heldBalances[a.toLowerCase()] ?? 0n)) throw Object.assign(new Error('too much'), { plain: `You hold ${tok(heldBalances[a.toLowerCase()] ?? 0n)} ${symOf(a)}; enter that or less.` });
    assets.push(a); amounts.push(v);
  }
  if (!assets.length) throw Object.assign(new Error('none'), { plain: 'Enter an amount for at least one Stock Token.' });
  return { assets, amounts };
}

/// Until the visitor touches the plan, suggest one that matches what they are
/// moving in, by value at the last published prices (even if expired: it is
/// only a starting point for a plan, not a price anything is bought at).
function suggestKindPlan() {
  if (kindPlanTouched) return;
  const vals = ASSETS.map(a => {
    const raw = String($(`ks-${a}`)?.value || '').trim();
    try { return raw ? valueOf(a, parseUnits(raw, 18)) : 0; } catch { return 0; }
  });
  const total = vals.reduce((s, v) => s + v, 0);
  if (!total) return;
  const pcts = vals.map(v => Math.round((100 * v) / total));
  const drift = 100 - pcts.reduce((s, p) => s + p, 0);
  pcts[pcts.indexOf(Math.max(...pcts))] += drift;
  kindMix.set(ASSETS.map((a, i) => ({ asset: a, pct: pcts[i] })));
  kindPlanTouched = false;
}

$('btnKindCreate').addEventListener('click', async () => {
  clearMsg('kindMsg');
  if (needWallet('kindMsg')) return;
  let sel;
  try { sel = readKind('ks'); } catch (e) { return showError('kindMsg', e); }
  if (!kindMix.valid()) return showMsg('kindMsg', 'warn', 'The plan needs to add up to exactly 100%.');
  const btn = $('btnKindCreate'); busy(btn, true, 'Starting…');
  const steps = stepper('kindSteps', [...sel.assets.map(a => `Allow exactly this much ${symOf(a)}`), 'Move them into a new basket']);
  let i = 0;
  try {
    for (; i < sel.assets.length; i++) await ensureAllowance(sel.assets[i], sel.amounts[i], steps, i);
    const { hash, receipt } = await sendStep(steps, i, { address: D.basket, abi: BASKET_ABI, functionName: 'createInKind', args: [kindMix.allocation(), sel.assets, sel.amounts] });
    const made = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'BasketCreated' })[0];
    log(`started basket #${made?.args.tokenId} with Stock Tokens already held`, 'ok', hash);
    await refreshWallet(false); await loadBaskets(); await renderKindRows();
    if (made) { freshHashes.add(hash); go(`?basket=${made.args.tokenId}`); }
  } catch (e) {
    steps.failFrom(i, wasRejected(e) ? 'cancelled in your wallet' : 'not done');
    showError('kindMsg', e);
    await refreshWallet(false);
  } finally { busy(btn, false); }
});

// ------------------------------------------------------------ one basket ----

async function readBasket(id) {
  const c = contractFor(id);
  if (!c) return null;
  const owner = await pub.readContract({ address: c.address, abi: c.abi, functionName: 'ownerOf', args: [id] }).catch(() => null);
  const b = { id, c, legacy: c.legacy, owner, exists: !!owner, assets: [], amounts: [], plan: [], count: null, funded: null, version: null };
  if (!owner) return b;
  const [h, plan] = await Promise.all([
    pub.readContract({ address: c.address, abi: c.abi, functionName: 'holdingsOf', args: [id] }),
    pub.readContract({ address: c.address, abi: c.abi, functionName: 'allocationOf', args: [id] }),
  ]);
  Object.assign(b, { assets: h[0], amounts: h[1], plan });
  if (c.counters) {
    const [count, funded, version] = await Promise.all(['fundingCount', 'totalFunded', 'allocationVersion']
      .map(f => pub.readContract({ address: c.address, abi: c.abi, functionName: f, args: [id] })));
    Object.assign(b, { count: Number(count), funded, version });
  }
  return b;
}

/// An outcome that changes what the viewer can do (a hand-over, a closing) is
/// shown above the basket, not inside a panel that is about to disappear.
let pendingNotice = null;
/// Transactions this page just confirmed: their history entries slide in.
const freshHashes = new Set();

/**
 * Show a basket. With `from` (the basket as it was before a confirmed
 * transaction), the changed rows flash and their numbers count from the old
 * amount to the new one, and a new owner is highlighted. Only a confirmed
 * receipt ever leads here, so nothing animates on a guess.
 */
async function showBasket(id, { from = null } = {}) {
  const b = await readBasket(id);
  current = b;
  if (pendingNotice) { showMsg('bvNotice', ...pendingNotice); pendingNotice = null; } else clearMsg('bvNotice');
  for (const m of ['addMsg', 'addKindMsg', 'copyMsg', 'outMsg', 'giveMsg', 'planMsg']) clearMsg(m);
  for (const t of ['outTx', 'giveTx', 'planTx']) $(t).hidden = true;
  if (!from) for (const s of ['addSteps', 'addKindSteps', 'copySteps']) $(s).hidden = true;
  $('addQuote').innerHTML = '';
  $('bvGhost').hidden = true;

  if (!b) {
    $('bvTitle').textContent = `Basket #${id}`;
    $('bvEyebrow').textContent = 'Not found';
    $('bvOwner').textContent = 'There is no such basket on this network.';
    $('bvActions').hidden = true;
    return;
  }
  const mine = isMine(b);
  document.title = `Basket #${id} · Jayo`;
  $('bvEyebrow').textContent = b.legacy ? `Basket · version ${b.c.version}, withdraw only` : 'Basket';
  $('bvTitle').textContent = `Basket #${id}`;
  $('bvExplorer').href = `${D.explorer}/token/${b.c.address}/instance/${id}`;
  $('bvExplorer').hidden = !D.explorer;
  $('bvOwner').innerHTML = !b.exists
    ? 'This basket has been <b>closed</b>: everything in it was taken out.'
    : mine ? '<span class="you">You own this basket.</span>' : `Owned by <b>${addrHtml(b.owner)}</b>`;
  $('bvOwner').classList.remove('changed');
  if (from && from.owner && b.owner && from.owner.toLowerCase() !== b.owner.toLowerCase() && !REDUCED) {
    void $('bvOwner').offsetWidth; $('bvOwner').classList.add('changed');
  }

  // Holdings, valued at the reference prices.
  const val = totalValue(b);
  $('bvValue').textContent = b.exists && val ? `≈ ${usd(val)} at reference prices` : '';
  ribbon('bvRibbon', holdingParts(b.assets, b.amounts));
  const before = new Map((from?.assets || []).map((a, i) => [a.toLowerCase(), from.amounts[i]]));
  $('bvRows').innerHTML = b.assets.length ? b.assets.map((a, i) => {
    const was = before.get(a.toLowerCase());
    const cls = from ? (was === undefined || b.amounts[i] > was ? 'flash-add' : b.amounts[i] < was ? 'flash-out' : '') : '';
    return `<tr style="--c:${colorOf(a)}" class="${cls}" data-asset="${a.toLowerCase()}">
      <td><span class="sym"><i></i>${esc(symOf(a))}</span><span class="name">${esc(META[a.toLowerCase()]?.name || '')}</span></td>
      <td class="num" data-amt="${b.amounts[i]}" data-was="${was ?? 0n}">${tok(b.amounts[i])}</td><td class="num">${usd(valueOf(a, b.amounts[i]))}</td></tr>`;
  }).join('')
    : `<tr><td colspan="3" class="muted">${b.exists ? 'It holds nothing.' : 'Closed: it holds nothing and cannot receive anything.'}</td></tr>`;
  if (from) countUp();

  // Plan for new money.
  ribbon('bvPlanRibbon', b.plan.map(p => ({ asset: p.asset, weight: Number(p.weightBps) })), { legend: false });
  $('bvPlanText').textContent = b.plan.length ? b.plan.map(p => `${symOf(p.asset)} ${Number(p.weightBps) / 100}%`).join(' · ') : 'No plan: the basket is closed.';
  $('bvPlanVersion').textContent = b.version ? `Version ${b.version}` : '';
  $('bvPlanNote').textContent = b.legacy
    ? `This basket is on version ${b.c.version} of Jayo, which takes no new money. Its owner can still take Stock Tokens out or hand it on, and anyone can start a new basket with this plan.`
    : 'Money added to this basket is split this way. The plan does not rebalance: it does not change what the basket already holds.';

  // Who can do what.
  const canOwn = b.exists && mine;
  $('tabOut').hidden = !canOwn; $('tabGive').hidden = !canOwn; $('tabPlan').hidden = !canOwn || b.legacy;
  $('tabAdd').hidden = b.legacy || !b.exists;
  $('tabCopy').hidden = !b.plan.length;
  $('ownerOnly').hidden = !b.exists || mine;
  $('ownerOnly').innerHTML = connected()
    ? `Only its owner, ${addrHtml(b.owner)}, can take Stock Tokens out, hand it on or change its plan.`
    : 'Connect your wallet. If this basket is yours, you can take Stock Tokens out, hand it on or change its plan here.';
  $('addLede').textContent = mine
    ? "Top up your basket with money, bought by its plan, or with Stock Tokens you already hold."
    : "Add to this basket as a gift: money, bought by its plan, or Stock Tokens you already hold. It all belongs to the basket's owner, and you get nothing back.";
  $('addGoesTo').innerHTML = b.exists && !b.legacy
    ? (mine ? 'Goes to: <b>you</b>.' : `Goes to: <b>${addrHtml(b.owner)}</b>, the owner now. If the basket changes hands before your addition is confirmed, it is refused and nothing is spent.`)
    : '';
  $('btnAdd').textContent = mine ? 'Top up my basket' : 'Add to this basket';

  // Take-out choices. One Stock Token left: "all of it" and "everything" are
  // the same thing, so only the part-way options and the closing one are offered.
  const several = b.assets.length > 1;
  $('outChoices').innerHTML = '<legend class="field-label">What to take out</legend>' + [
    ...(several ? b.assets.map((a, i) => ({ v: `asset:${a}`, t: `All of the ${symOf(a)}`, amt: `${tok(b.amounts[i])}` })) : []),
    { v: 'frac:2500', t: several ? 'A quarter of everything' : `A quarter of the ${symOf(b.assets[0] || '')}` },
    { v: 'frac:5000', t: several ? 'Half of everything' : `Half of the ${symOf(b.assets[0] || '')}` },
    { v: 'all', t: 'Everything, and close the basket' },
  ].map((c, i) => `<label><input type="radio" name="out" value="${esc(c.v)}" ${i === 0 ? 'checked' : ''}> ${esc(c.t)}${c.amt ? `<span class="amt">${esc(c.amt)}</span>` : ''}</label>`).join('');

  if (!b.legacy && canOwn) {
    const rows = ASSETS.map(a => ({ asset: a, pct: Number(b.plan.find(p => p.asset.toLowerCase() === a.toLowerCase())?.weightBps ?? 0) / 100 }));
    planMix ? planMix.set(rows) : (planMix = mixEditor('planMix', rows));
  }
  if (!from) resetGive();

  const visible = [...$('bvTabs').querySelectorAll('[role=tab]')].filter(t => !t.hidden);
  const keep = visible.find(t => t.getAttribute('aria-selected') === 'true');
  if (visible.length) selectTab(keep || visible[0]);
  else for (const p of document.querySelectorAll('.bv-actions [role=tabpanel]')) p.hidden = true;
  $('bvActions').hidden = !visible.length;
  applyBuyingState();
  schedulePreview();
  renderHistory(b).catch(() => { $('bvHistory').innerHTML = '<li class="muted">The history could not be read just now.</li>'; });
}

/// Count changed amounts from their old value to their confirmed new one.
function countUp() {
  const cells = [...document.querySelectorAll('#bvRows td[data-amt]')].filter(td => td.dataset.amt !== td.dataset.was);
  if (REDUCED || !cells.length) return;
  const t0 = performance.now(), dur = 900;
  const from = cells.map(td => Number(formatUnits(BigInt(td.dataset.was), 18)));
  const to = cells.map(td => Number(formatUnits(BigInt(td.dataset.amt), 18)));
  const frame = now => {
    const k = Math.min(1, (now - t0) / dur);
    const e = 1 - Math.pow(1 - k, 3);
    cells.forEach((td, i) => {
      td.textContent = k < 1 ? (from[i] + (to[i] - from[i]) * e).toLocaleString(NUM, { maximumFractionDigits: 6 }) : tok(BigInt(td.dataset.amt));
    });
    if (k < 1) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

// Tabs, with arrow-key movement between them.
function selectTab(tab) {
  if (!tab) return;
  for (const t of $('bvTabs').querySelectorAll('[role=tab]')) {
    const on = t === tab;
    t.setAttribute('aria-selected', String(on));
    t.tabIndex = on ? 0 : -1;
    $(t.getAttribute('aria-controls')).hidden = !on;
  }
  schedulePreview();
}
$('bvTabs').addEventListener('click', ev => { const t = ev.target.closest('[role=tab]'); if (t) selectTab(t); });
$('bvTabs').addEventListener('keydown', ev => {
  if (!['ArrowRight', 'ArrowLeft'].includes(ev.key)) return;
  const tabs = [...$('bvTabs').querySelectorAll('[role=tab]')].filter(t => !t.hidden);
  const i = tabs.indexOf(document.activeElement);
  const next = tabs[(i + (ev.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
  selectTab(next); next.focus();
});

$('btnShare').addEventListener('click', async () => {
  const url = `${location.origin}${location.pathname}?basket=${current?.id}`;
  try { await navigator.clipboard.writeText(url); $('btnShare').textContent = 'Link copied'; }
  catch { window.prompt('Copy this link', url); }
  setTimeout(() => { $('btnShare').textContent = 'Copy link'; }, 2500);
});

// ------------------------------------------------------- live addition preview
//
// While "Add money" is open with an amount and fresh prices, the contract's own
// previewContribute says what each leg would get. That is drawn as a dashed
// ribbon of the basket after the addition, and as "+ about …" per row - an
// estimate, labelled as one, never mixed with what the basket holds.

let previewTimer = null;
function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => previewAddition().catch(() => {}), 300);
}
$('addAmt').addEventListener('input', () => { clearMsg('addMsg'); schedulePreview(); });

async function previewAddition() {
  const b = current;
  const show = b && b.exists && !b.legacy && !$('paneAdd').hidden && !$('addMoney').hidden && buyingOpen;
  document.querySelectorAll('#bvRows .gain, #bvRows tr.ghost-row').forEach(g => g.remove());
  if (!show) { $('bvGhost').hidden = true; $('addQuote').innerHTML = ''; return; }
  let amount;
  try { amount = parseAmount('addAmt'); } catch { $('bvGhost').hidden = true; $('addQuote').innerHTML = ''; return; }
  const [ins, refs, floors, unspent] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'previewContribute', args: [b.id, amount] });
  if (current !== b) return;
  const assets = b.plan.map(p => p.asset);
  $('addQuote').innerHTML = quoteHtml(amount, assets, ins, refs, floors, unspent,
    isMine(b) ? 'you' : `${addrHtml(b.owner)} (owner now)`);
  // The basket after the addition, by value, at the reference prices.
  const after = new Map(b.assets.map((a, i) => [a.toLowerCase(), b.amounts[i]]));
  assets.forEach((a, i) => after.set(a.toLowerCase(), (after.get(a.toLowerCase()) || 0n) + refs[i]));
  const all = [...after.keys()];
  ribbon('bvGhostRibbon', all.map(k => ({ asset: k, weight: valueOf(k, after.get(k)) })), { legend: false });
  $('bvGhostNote').textContent = `The basket after your ${usdg(amount)} ${stableSym()}, estimated at reference prices. What is actually bought is shown once it is confirmed.`;
  $('bvGhost').hidden = false;
  assets.forEach((a, i) => {
    const td = document.querySelector(`#bvRows tr[data-asset="${a.toLowerCase()}"] td.num`);
    if (td) td.insertAdjacentHTML('beforeend', `<span class="gain">+ about ${tok(refs[i])}</span>`);
    // A Stock Token in the plan that the basket does not hold yet gets an
    // estimate row of its own, marked as such.
    else $('bvRows').insertAdjacentHTML('beforeend', `<tr class="ghost-row" style="--c:${colorOf(a)}">
      <td><span class="sym"><i></i>${esc(symOf(a))}</span><span class="name">not held yet</span></td>
      <td class="num">—<span class="gain">+ about ${tok(refs[i])}</span></td><td class="num"></td></tr>`);
  });
}

// ----------------------------------------------------------------- history ---

/// Every event a basket contract has emitted since it was deployed. Not cached:
/// the history is read right after a purchase, and a cached block number (viem
/// keeps one for a few seconds) would stop the query one block short of it.
async function contractLogs(address, fromBlock) {
  const raw = await pub.getLogs({ address, fromBlock: BigInt(fromBlock || 0), toBlock: 'latest' });
  return parseEventLogs({ abi: EVENTS, logs: raw, strict: false });
}

async function renderHistory(b) {
  const logs = (await contractLogs(b.c.address, b.c.deployBlock))
    .filter(l => l.args?.tokenId === b.id || l.args?.newTokenId === b.id || l.args?.sourceTokenId === b.id);
  const byTx = new Map();
  for (const l of logs) { if (!byTx.has(l.transactionHash)) byTx.set(l.transactionHash, []); byTx.get(l.transactionHash).push(l); }
  const blocks = [...new Set(logs.map(l => l.blockNumber))];
  const times = Object.fromEntries(await Promise.all(blocks.map(async n => [n, Number((await pub.getBlock({ blockNumber: n })).timestamp)])));
  const isYou = a => a?.toLowerCase() === me();
  const who = a => (isYou(a) ? 'you' : addrHtml(a));
  const Who = a => (isYou(a) ? 'You' : addrHtml(a));
  const amt = (v, a) => `${tok(v)} ${esc(symOf(a))}`;
  const bought = ls => ls.filter(l => l.eventName === 'LegSettled').map(l => amt(l.args.acquired, l.args.asset)).join(' and ');
  const moved = ls => ls.filter(l => l.eventName === 'DepositedInKind').map(l => amt(l.args.amount, l.args.asset)).join(' and ');
  const taken = ls => ls.filter(l => l.eventName === 'AssetRedeemed').map(l => amt(l.args.amount, l.args.asset)).join(' and ');
  const cash = v => `${usdg(v)} ${esc(stableSym())}`;

  const items = [];
  for (const [hash, ls] of byTx) {
    const t = times[ls[0].blockNumber];
    const ev = name => ls.find(l => l.eventName === name);
    let cls = '', html = '';
    if (ev('BasketCreated')) {
      const c = ev('BasketCreated'); const copied = ev('AllocationCopied');
      html = moved(ls)
        ? `Started by ${who(c.args.creator)} with Stock Tokens already held: ${moved(ls)}.`
        : `${copied ? `Started from basket <a href="?basket=${copied.args.sourceTokenId}" data-route="1">#${copied.args.sourceTokenId}</a>'s plan` : 'Created'} by ${who(c.args.creator)} with ${cash(c.args.usdgSpent)}${bought(ls) ? `: bought ${bought(ls)}` : ''}.`;
    } else if (ev('Contributed')) {
      const c = ev('Contributed'); cls = 'add';
      html = `${Who(c.args.contributor)} added ${cash(c.args.usdgSpent)}: bought ${bought(ls)}.`;
    } else if (ev('DepositedInKind')) {
      cls = 'add';
      const d = ev('DepositedInKind').args.depositor;
      html = `${Who(d)} moved in ${moved(ls)} ${isYou(d) ? 'you' : 'they'} already held.`;
    } else if (ev('AllocationCopied')) {
      const c = ev('AllocationCopied');
      html = `${Who(c.args.creator)} started basket <a href="?basket=${c.args.newTokenId}" data-route="1">#${c.args.newTokenId}</a> with this plan, using ${isYou(c.args.creator) ? 'your' : 'their'} own money.`;
    } else if (ev('PositionClosed') || ev('BasketRedeemed')) {
      cls = 'out';
      const to = ev('PositionClosed')?.args.lastOwner || ev('BasketRedeemed')?.args.to;
      html = `Closed: ${taken(ls) || 'everything'} went to ${who(to)}.`;
    } else if (ev('AssetRedeemed')) {
      cls = 'out';
      html = `${taken(ls)} taken out by ${who(ev('AssetRedeemed').args.to)}.`;
    } else if (ev('AllocationChanged')) {
      html = `Plan changed to ${ev('AllocationChanged').args.allocation.map(p => `${esc(symOf(p.asset))} ${Number(p.weightBps) / 100}%`).join(' · ')}.`;
    } else if (ev('Transfer')) {
      const c = ev('Transfer'); cls = 'give';
      if (/^0x0{40}$/i.test(c.args.from) || /^0x0{40}$/i.test(c.args.to)) continue; // mint and burn are told above
      html = `Handed from ${who(c.args.from)} to ${who(c.args.to)}.`;
    } else continue;
    if (freshHashes.has(hash)) { cls += ' fresh'; freshHashes.delete(hash); }
    const url = txUrl(hash);
    items.push({ t, html: `<li class="${cls}">${html}<span class="when">${new Date(t * 1000).toLocaleString(NUM, { dateStyle: 'medium', timeStyle: 'short' })}${url ? ` · <a href="${url}" target="_blank" rel="noopener noreferrer">receipt</a>` : ''}</span></li>` });
  }
  items.sort((x, y) => y.t - x.t);
  $('bvHistory').innerHTML = items.map(i => i.html).join('') || '<li class="muted">No events found.</li>';
}

// --------------------------------------------------------------- add money ---

$('btnAdd').addEventListener('click', async () => {
  clearMsg('addMsg');
  if (needWallet('addMsg')) return;
  const b = current;
  const btn = $('btnAdd'); busy(btn, true, 'Adding…');
  const steps = stepper('addSteps', [`Allow exactly this much ${stableSym()}`, `Buy into basket #${b.id}`]);
  let estimate = null;
  try {
    const amount = parseAmount('addAmt');
    await stillAsShown(b);
    estimate = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'previewContribute', args: [b.id, amount] });
    await ensureAllowance(D.usdg, amount, steps, 0);
    // The owner and plan version this page showed: if either changed, it reverts.
    const { hash, receipt } = await sendStep(steps, 1, { address: D.basket, abi: BASKET_ABI, functionName: 'contribute', args: [b.id, amount, b.owner, b.version, await deadline()] });
    const legs = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'LegSettled' });
    const actual = legs.map(l => {
      const i = b.plan.findIndex(p => p.asset.toLowerCase() === l.args.asset.toLowerCase());
      return `${tok(l.args.acquired)} ${symOf(l.args.asset)}${i >= 0 ? ` (estimate ${tok(estimate[1][i])})` : ''}`;
    }).join(' and ');
    log(`added ${formatUnits(amount, 6)} ${stableSym()} to basket #${b.id}`, 'ok', hash);
    freshHashes.add(hash);
    $('addAmt').value = ''; // done: no estimate of a further addition until one is typed
    await refreshWallet(false); await loadBaskets(); await showBasket(b.id, { from: b });
    showMsg('addMsg', 'success', `Added to basket #${b.id}.`, `Bought ${esc(actual)}. ${isMine(b) ? 'Your basket holds more now.' : "It now belongs to the basket's owner."}`);
  } catch (e) {
    steps.failFrom([...$('addSteps').children].findIndex(li => ['active', 'pending', 'waiting'].includes(li.dataset.state)), wasRejected(e) ? 'cancelled in your wallet' : 'not done');
    const name = decode(e)?.name;
    if (name === 'AllocationChangedSinceQuote' || name === 'OwnerChangedSinceQuote') await showBasket(b.id);
    showError('addMsg', e);
  } finally { busy(btn, false); applyBuyingState(); }
});

$('btnAddKind').addEventListener('click', async () => {
  clearMsg('addKindMsg');
  if (needWallet('addKindMsg')) return;
  const b = current;
  let sel;
  try { sel = readKind('ka'); } catch (e) { return showError('addKindMsg', e); }
  const btn = $('btnAddKind'); busy(btn, true, 'Moving…');
  const steps = stepper('addKindSteps', [...sel.assets.map(a => `Allow exactly this much ${symOf(a)}`), `Move them into basket #${b.id}`]);
  let i = 0;
  try {
    await stillAsShown(b);
    for (; i < sel.assets.length; i++) await ensureAllowance(sel.assets[i], sel.amounts[i], steps, i);
    const { hash, receipt } = await sendStep(steps, i, { address: D.basket, abi: BASKET_ABI, functionName: 'depositInKind', args: [b.id, b.owner, sel.assets, sel.amounts] });
    const moved = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'DepositedInKind' }).map(l => `${tok(l.args.amount)} ${symOf(l.args.asset)}`).join(' and ');
    log(`moved ${moved} into basket #${b.id}`, 'ok', hash);
    freshHashes.add(hash);
    await refreshWallet(false); await loadBaskets(); await renderKindRows(); await showBasket(b.id, { from: b });
    showMsg('addKindMsg', 'success', `Moved ${moved} into basket #${b.id}.`, isMine(b) ? 'Nothing was bought or sold.' : "They now belong to the basket's owner. Nothing was bought or sold.");
  } catch (e) {
    steps.failFrom(i, wasRejected(e) ? 'cancelled in your wallet' : 'not done');
    if (decode(e)?.name === 'OwnerChangedSinceQuote') await showBasket(b.id);
    showError('addKindMsg', e);
    await refreshWallet(false);
  } finally { busy(btn, false); }
});

// -------------------------------------------------------------------- copy ---

$('btnCopy').addEventListener('click', async () => {
  clearMsg('copyMsg');
  if (needWallet('copyMsg')) return;
  const b = current;
  const btn = $('btnCopy'); busy(btn, true, 'Buying…');
  const steps = stepper('copySteps', [`Allow exactly this much ${stableSym()}`, 'Buy your own basket with this plan']);
  try {
    const amount = parseAmount('copyAmt');
    await ensureAllowance(D.usdg, amount, steps, 0);
    // The current version copies natively and records where the plan came from.
    // An earlier version's plan is copied by creating a new basket with it.
    const params = b.legacy
      ? { address: D.basket, abi: BASKET_ABI, functionName: 'create', args: [b.plan.map(p => ({ asset: p.asset, weightBps: Number(p.weightBps) })), amount, await deadline()] }
      : { address: D.basket, abi: BASKET_ABI, functionName: 'copyAllocation', args: [b.id, amount, b.version, await deadline()] };
    const { hash, receipt } = await sendStep(steps, 1, params);
    const made = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'BasketCreated' })[0];
    log(`started basket #${made?.args.tokenId} with basket #${b.id}'s plan`, 'ok', hash);
    await refreshWallet(false); await loadBaskets();
    if (made) { freshHashes.add(hash); go(`?basket=${made.args.tokenId}`); }
  } catch (e) {
    steps.failFrom([...$('copySteps').children].findIndex(li => ['active', 'pending', 'waiting'].includes(li.dataset.state)), wasRejected(e) ? 'cancelled in your wallet' : 'not done');
    showError('copyMsg', e);
  } finally { busy(btn, false); applyBuyingState(); }
});

// ---------------------------------------------------------------- take out ---

$('btnOut').addEventListener('click', async () => {
  clearMsg('outMsg');
  if (needWallet('outMsg')) return;
  const b = current;
  const choice = document.querySelector('input[name="out"]:checked')?.value;
  if (!choice) return;
  const btn = $('btnOut'); busy(btn, true, 'Sending…');
  try {
    const [kind, value] = choice.split(':');
    const { address, abi } = b.c;
    tx('outTx', 'signing', 'Sending the Stock Tokens to your wallet: confirm in your wallet…');
    const hash = kind === 'asset' ? await send({ address, abi, functionName: 'redeemAsset', args: [b.id, value] })
      : kind === 'frac' ? await send({ address, abi, functionName: 'redeemFraction', args: [b.id, Number(value)] })
      : await send({ address, abi, functionName: 'redeem', args: [b.id] });
    tx('outTx', 'pending', 'Waiting for confirmation…', hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    const sent = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'AssetRedeemed' })
      .map(l => `${tok(l.args.amount)} ${symOf(l.args.asset)}`).join(' and ');
    const closed = parseEventLogs({ abi: EVENTS, logs: receipt.logs }).some(l => l.eventName === 'PositionClosed' || l.eventName === 'BasketRedeemed');
    tx('outTx', 'confirmed', 'Sent to your wallet', hash);
    log(`took ${sent} out of basket #${b.id}`, 'ok', hash);
    freshHashes.add(hash);
    if (closed) pendingNotice = ['success', `Sent ${sent || 'the Stock Tokens'} to your wallet.`, 'That was the last of it, so the basket is closed. Its history stays readable here.'];
    await refreshWallet(false); await loadBaskets(); await renderKindRows(); await showBasket(b.id, { from: b });
    if (!closed) showMsg('outMsg', 'success', `Sent ${sent || 'the Stock Tokens'} to your wallet.`, 'The basket is still yours and holds the rest. No price was needed for this.');
  } catch (e) { tx('outTx', 'failed', 'Cancelled: nothing was sent'); showError('outMsg', e); }
  finally { busy(btn, false); }
});

// ----------------------------------------------------------------- hand on ---
//
// No default recipient: the address is typed or pasted, validated as it is
// entered, and nothing is signed until a separate confirmation names the full
// address and what is being handed on.

let recipient = null;

function hintRecipient(text, bad) {
  $('toAddrHint').textContent = text;
  $('toAddrHint').style.color = bad ? 'var(--bad)' : '';
  $('toAddr').setAttribute('aria-invalid', bad ? 'true' : 'false');
}

function validateRecipient() {
  recipient = null;
  $('btnGiveReview').disabled = true;
  const raw = $('toAddr').value.trim();
  if (!raw) return hintRecipient('Paste the address of the person receiving it.', false);
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) return hintRecipient('That is not a wallet address. It should be 0x followed by 40 letters and numbers.', true);
  const body = raw.slice(2);
  const mixed = body !== body.toLowerCase() && body !== body.toUpperCase();
  if (mixed && !isAddress(raw, { strict: true })) return hintRecipient('This address has a typo: its capital letters do not match its checksum. Copy it again.', true);
  const addr = getAddress(raw);
  if (/^0x0{40}$/i.test(addr)) return hintRecipient('That is the zero address. Anything sent there is gone for good.', true);
  if (addr.toLowerCase() === me()) return hintRecipient('That is your own address.', true);
  const known = [D.basket, D.legacyBasket, D.legacyBasket2, D.usdg, D.gateway, D.policy, D.adapter, D.poolManager, D.renderer, ...(D.stocks || [])]
    .filter(Boolean).map(a => a.toLowerCase());
  if (known.includes(addr.toLowerCase())) return hintRecipient("That is one of Jayo's own contracts, not a person. It could never give the basket back.", true);
  recipient = addr;
  hintRecipient('Looks like a valid address. You will confirm it before anything is sent.', false);
  $('btnGiveReview').disabled = false;
}

function resetGive() {
  $('toAddr').value = '';
  $('giveConfirm').hidden = true;
  $('gcAck').checked = false;
  $('btnGive').disabled = true;
  validateRecipient();
}

$('toAddr').addEventListener('input', () => { $('giveConfirm').hidden = true; $('gcAck').checked = false; clearMsg('giveMsg'); validateRecipient(); });

$('btnGiveReview').addEventListener('click', async () => {
  validateRecipient();
  if (!recipient) return;
  const b = current;
  const code = await pub.getCode({ address: recipient });
  $('gcId').textContent = `#${b.id}`;
  $('gcHoldings').textContent = b.assets.length ? b.assets.map((a, i) => `${tok(b.amounts[i])} ${symOf(a)}`).join(' and ') : 'nothing';
  $('gcAddr').textContent = recipient;
  $('gcWarn').textContent = code && code !== '0x' ? 'This address is a contract, not a personal wallet. If it cannot hold baskets, the hand-over is refused and nothing moves.' : '';
  $('giveConfirm').hidden = false;
  $('gcAck').focus();
});
$('gcAck').addEventListener('change', () => { $('btnGive').disabled = !$('gcAck').checked; });
$('btnGiveCancel').addEventListener('click', () => { $('giveConfirm').hidden = true; $('gcAck').checked = false; $('btnGiveReview').focus(); });

$('btnGive').addEventListener('click', async () => {
  if (!recipient || !$('gcAck').checked) return;
  clearMsg('giveMsg');
  if (needWallet('giveMsg')) return;
  const b = current; const to = recipient;
  const btn = $('btnGive'); busy(btn, true, 'Handing on…');
  try {
    tx('giveTx', 'signing', 'Handing the basket on: confirm in your wallet…');
    // safeTransferFrom: a contract that cannot hold ERC-721s makes it revert
    // instead of swallowing the basket.
    const hash = await send({ address: b.c.address, abi: b.c.abi, functionName: 'safeTransferFrom', args: [account().address, to, b.id] });
    tx('giveTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    tx('giveTx', 'confirmed', 'Handed on', hash);
    log(`handed basket #${b.id} to ${short(to)}`, 'ok', hash);
    freshHashes.add(hash);
    pendingNotice = ['success', `Basket #${b.id} now belongs to ${short(to)}.`,
      "You can no longer take Stock Tokens out of it or hand it on. Send them this page's link (Copy link, above) so they can see exactly what they received."];
    await loadBaskets(); await showBasket(b.id, { from: b });
  } catch (e) { tx('giveTx', 'failed', 'Cancelled: nothing moved'); showError('giveMsg', e); }
  finally { busy(btn, false); }
});

// ------------------------------------------------------------- change plan ---

$('btnPlan').addEventListener('click', async () => {
  clearMsg('planMsg');
  if (needWallet('planMsg')) return;
  if (!planMix.valid()) return showMsg('planMsg', 'warn', 'The plan needs to add up to exactly 100%.');
  const b = current;
  const btn = $('btnPlan'); busy(btn, true, 'Saving…');
  try {
    tx('planTx', 'signing', 'Saving the new plan: confirm in your wallet…');
    const hash = await send({ address: D.basket, abi: BASKET_ABI, functionName: 'setAllocation', args: [b.id, planMix.allocation()] });
    tx('planTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    tx('planTx', 'confirmed', 'Plan saved', hash);
    log(`changed basket #${b.id}'s plan`, 'ok', hash);
    freshHashes.add(hash);
    await loadBaskets(); await showBasket(b.id, { from: b });
    showMsg('planMsg', 'success', 'Saved.', 'Money added from now on is split this way. Nothing the basket holds was sold or bought.');
  } catch (e) { tx('planTx', 'failed', 'Not saved'); showError('planMsg', e); }
  finally { busy(btn, false); }
});

/* @local-only-start */
// ------------------------------------------------------------ demo panel ----

$('btnAcct').addEventListener('click', async () => {
  acctIndex = (acctIndex + 1) % LOCAL_ACCOUNTS.length;
  await afterAccountChange();
  showMsg('demoMsg', 'info', `Now acting as ${LOCAL.label()} (${short(account().address)}).`);
});

$('btnFillOther').addEventListener('click', () => {
  $('toAddr').value = privateKeyToAccount(LOCAL_ACCOUNTS[(acctIndex + 1) % LOCAL_ACCOUNTS.length].key).address;
  $('toAddr').dispatchEvent(new Event('input'));
});

$('btnTime').addEventListener('click', async () => {
  await pub.request({ method: 'evm_increaseTime', params: [172800] });
  await pub.request({ method: 'evm_mine', params: [] });
  await renderPrices();
  showMsg('demoMsg', 'warn', 'Prices are now two days old.', 'Buying refuses. Moving in Stock Tokens you hold and taking them out still work.');
});

$('btnRefresh').addEventListener('click', async () => {
  const btn = $('btnRefresh'); busy(btn, true, 'Refreshing…');
  try {
    // The local feeds accept their owner, Wallet A, whichever wallet is acting.
    const w = createWalletClient({ account: privateKeyToAccount(LOCAL_ACCOUNTS[0].key), chain, transport: http(LOCAL.rpc) });
    for (const [feed, price] of [[D.aaplFeed, 255_00000000n], [D.nvdaFeed, 150_00000000n], [D.usdgFeed, 1_00000000n]]) {
      const h = await w.writeContract({ address: feed, abi: FEED_ABI, functionName: 'setAnswer', args: [price] });
      await pub.waitForTransactionReceipt({ hash: h });
    }
    await renderPrices();
    showMsg('demoMsg', 'success', 'Prices are current again.');
  } catch (e) { showError('demoMsg', e); }
  finally { busy(btn, false); }
});
/* @local-only-end */

boot();
