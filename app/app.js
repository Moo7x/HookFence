// =============================================================================
// Jayo interface
//
// Design goals, in priority order:
//   1. A basket is the product. Anyone who lands on one - by link, from a card -
//      can see exactly what it holds, how new money into it is split, who owns
//      it, what has happened to it, and what THEY can do with it.
//   2. Every rejection says, in plain words, what happened and what to change.
//      The contract's own error stays available, folded away.
//   3. Transaction state is always explicit: signing, pending, confirmed or
//      failed, with a link to the receipt. Never a button that silently does
//      nothing.
//
// Two contracts are read. Version 2 is where everything new happens. Version 1
// is immutable and stays live: its baskets are listed, can be withdrawn and
// handed on, and their plans can be copied into a new version-2 basket - they
// cannot receive additions, and the page says so.
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

// Version 2: everything the page reads and writes on a current basket.
const BASKET_ABI = [
  view('previewCreate', [{ name: 'allocation', ...ALLOC }, 'uint256'], ['uint256[]', 'uint256[]', 'uint256[]', 'uint256']),
  view('previewContribute', ['uint256', 'uint256'], ['uint256[]', 'uint256[]', 'uint256[]', 'uint256']),
  fn('create', [{ name: 'allocation', ...ALLOC }, 'uint256', 'uint256'], ['uint256']),
  fn('contribute', ['uint256', 'uint256', 'uint64', 'uint256']),
  fn('copyAllocation', ['uint256', 'uint256', 'uint64', 'uint256'], ['uint256']),
  fn('setAllocation', ['uint256', { name: 'allocation', ...ALLOC }]),
  view('holdingsOf', ['uint256'], ['address[]', 'uint256[]']),
  view('allocationOf', ['uint256'], [{ ...ALLOC }]),
  view('allocationVersion', ['uint256'], ['uint64']),
  view('totalFunded', ['uint256'], ['uint256']),
  view('fundingCount', ['uint256'], ['uint32']),
  view('ownerOf', ['uint256'], ['address']),
  view('firstTokenId', [], ['uint256']),
  view('nextTokenId', [], ['uint256']),
  view('minLegInput', [], ['uint256']),
  fn('safeTransferFrom', ['address', 'address', 'uint256']),
  fn('redeem', ['uint256']),
  fn('redeemAsset', ['uint256', 'address']),
  fn('redeemFraction', ['uint256', 'uint16']),
  ...ERRORS, ...EVENTS,
];
// Version 1: read, withdraw, hand on. Nothing that buys.
const LEGACY_ABI = BASKET_ABI.filter(x => x.type !== 'function' ||
  ['holdingsOf', 'allocationOf', 'ownerOf', 'safeTransferFrom', 'redeem', 'redeemAsset', 'redeemFraction'].includes(x.name));

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
let ASSETS = [];              // buyable stock tokens
let PRICES = {};              // address -> { price8, updatedAt, maxStale }
let buyingOpen = false;
let chainNow = 0;
let firstV2 = 1n;
let baskets = [];             // every live basket, both versions
let current = null;           // the basket on screen
let minLeg = 1_000000n;
const PALETTE = ['#0B5563', '#EE6A4C', '#E6B23A', '#5B9FD1', '#7E5AA2', '#3E9E86', '#C7577A', '#8A6D52'];
const NUM = 'en-US';          // one locale, so separators never mix in a sentence

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
  LegBelowMinimum: a => ({ title: `The ${symOf(a[0])} part is only ${usdg(a[1])} ${stableSym()}.`, fix: `Each stock needs at least ${usdg(a[2])} ${stableSym()}. Put in more, or give it a bigger share.` }),
  LegWouldAcquireNothing: a => ({ title: `The ${symOf(a[0])} part is too small to buy anything.`, fix: 'It would spend money for zero tokens, so it was stopped. Increase the amount or that share.' }),
  LegAcquiredNothing: a => ({ title: `The ${symOf(a[0])} purchase came back empty.`, fix: 'Nothing was spent. The pool may not have enough liquidity right now.' }),
  DuplicateAsset: a => ({ title: `${symOf(a[0])} appears twice.`, fix: 'Give each stock one share.' }),
  AssetNotSupported: a => ({ title: `${symOf(a[0])} cannot be bought here.`, fix: 'Only stocks with a reviewed trading route can be. Pick another.' }),
  NoLegs: () => ({ title: 'The mix is empty.', fix: 'Give at least one stock a share.' }),
  TooManyLegs: a => ({ title: `${a[0]} stocks is too many.`, fix: `A basket can hold at most ${a[1]}.` }),
  NotPositionOwner: () => ({ title: 'Only the owner can do that.', fix: 'If this basket was handed on, control went with it.' }),
  AllocationChangedSinceQuote: () => ({ title: "The owner changed this basket's plan a moment ago.", fix: 'Nothing was spent. The page now shows the new plan: check it, then try again.' }),
  PositionDoesNotExist: a => ({ title: `Basket #${a[0]} does not exist any more.`, fix: 'Nothing was spent.' }),
  OutputBelowFloor: a => ({
    title: 'The pool would have given too little, so the purchase was stopped.',
    fix: `One stock would have come to ${tok(a[0])}; the reference price requires at least ${tok(a[1])}. Nothing was spent. ` +
      (D?.priceSource === 'pool'
        ? 'The test pools are small: recent purchases may have moved the price since it was last published, or this amount is too large for them. A smaller amount moves the price less.'
        : 'Try a smaller amount, which moves the price less.'),
  }),
  InputOverspent: () => ({ title: 'The purchase tried to spend more than you allowed.', fix: 'It was cancelled and nothing left your wallet.' }),
  IntentExpired: () => ({ title: 'This took too long and expired.', fix: 'Nothing was spent. Try again.' }),
  FeedStale: () => ({ title: 'There is no current price, so buying is paused.', fix: 'Jayo refuses to buy without a fresh reference price. Taking tokens out and handing baskets on still work.' }),
  FeedAnswerNotPositive: () => ({ title: 'The price feed returned an invalid value.', fix: 'Buying is paused until it recovers. Taking tokens out still works.' }),
  OraclePausedForCorporateAction: a => ({ title: `${symOf(a[0])} is paused by its issuer.`, fix: 'This happens around dividends or share splits. Taking tokens out still works.' }),
  CorporateActionPending: a => ({ title: `${symOf(a[0])} has a change taking effect shortly.`, fix: 'Jayo does not buy across that moment. Try again afterwards.' }),
  ERC721InsufficientApproval: () => ({ title: 'This basket is not yours to move.', fix: 'Switch to the wallet that owns it.' }),
  ERC20InsufficientBalance: () => ({ title: `You do not have enough ${stableSym()}.`, fix: 'Get more test rUSDG from your wallet panel, or use a smaller amount.' }),
  ERC20InsufficientAllowance: () => ({ title: 'The spending permission was too small.', fix: 'Nothing was spent. Try again; the page asks for exactly the amount needed.' }),
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

function showError(target, e) {
  const dec = decode(e);
  const rejected = /reject|denied|cancel/i.test(e?.shortMessage || e?.message || '') && !dec;
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

/// Approve exactly `amount` for the version-2 basket if the standing permission
/// is smaller. Never an open-ended allowance.
async function ensureAllowance(amount, txId) {
  // Check the balance before asking for anything: a permission for money the
  // wallet does not have would cost a transaction and then fail anyway.
  const balance = await pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'balanceOf', args: [account().address] });
  if (balance < amount) {
    throw Object.assign(new Error('insufficient balance'), {
      plain: `You have ${usdg(balance)} ${stableSym()}, which is less than ${usdg(amount)}. Get more test rUSDG from your wallet panel (top right), or use a smaller amount. Nothing was sent.`,
    });
  }
  const allowance = await pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'allowance', args: [account().address, D.basket] });
  if (allowance >= amount) return;
  tx(txId, 'signing', `Allow Jayo to use exactly ${formatUnits(amount, 6)} ${stableSym()} for this: confirm in your wallet…`);
  const h = await send({ address: D.usdg, abi: ERC20_ABI, functionName: 'approve', args: [D.basket, amount] });
  tx(txId, 'pending', 'Waiting for the permission to confirm…', h);
  await pub.waitForTransactionReceipt({ hash: h });
  log(`allowed Jayo to use exactly ${formatUnits(amount, 6)} ${stableSym()}`, 'ok', h);
}

function parseAmount(id) {
  const raw = String($(id).value || '').replace(/,/g, '').trim();
  if (!/^\d+(\.\d{0,6})?$/.test(raw)) throw Object.assign(new Error('bad amount'), { plain: 'Enter an amount like 20 or 12.5.' });
  const v = parseUnits(raw, 6);
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
  await route();
}

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
  [firstV2, minLeg] = await Promise.all([
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'firstTokenId' }),
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'minLegInput' }),
  ]);
  document.querySelectorAll('[data-unit], #fundUnit').forEach(el => { el.textContent = stableSym(); });
  if (D.suggestedFund) $('fund').value = formatUnits(BigInt(D.suggestedFund), 6);
  $('sizeGuide').hidden = D.priceSource !== 'pool';

  createMix = mixEditor('createMix', ASSETS.map((a, i) => ({ asset: a, pct: i === 0 ? 60 : Math.floor(40 / (ASSETS.length - 1)) })), () => {
    ribbon('createRibbon', createMix.rows().map(r => ({ asset: r.asset, weight: r.pct })), { legend: false });
    clearMsg('createMsg'); $('createQuote').innerHTML = '<p class="muted">Check what you would get before you buy.</p>';
    applyBuyingState();
  });
  ribbon('createRibbon', createMix.rows().map(r => ({ asset: r.asset, weight: r.pct })), { legend: false });

  describePrices();
  await renderPrices();
  setInterval(() => renderPrices().catch(() => {}), 30_000);
  await refreshWallet(false);
  await loadBaskets();
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

// Same-page links (cards, "All baskets") route without a reload.
document.addEventListener('click', ev => {
  const a = ev.target.closest('a[data-route]');
  if (!a || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button !== 0) return;
  ev.preventDefault();
  go(a.getAttribute('href'));
});
$('backLink').dataset.route = '1';

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
  chainNow = Number(blk.timestamp);
  PRICES = {};
  let oldest = 0; let minLeft = Infinity;
  assets.forEach((a, i) => {
    const updatedAt = Number(rounds[i][3]);
    const maxStale = Number(cfgs[i].maxStaleness);
    PRICES[a.toLowerCase()] = { price8: rounds[i][1], updatedAt, maxStale };
    oldest = Math.max(oldest, chainNow - updatedAt);
    minLeft = Math.min(minLeft, maxStale - (chainNow - updatedAt));
  });
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
        <strong>Taking tokens out and handing baskets on still work.</strong></div></div>`;
  for (const id of ['createBuyState', 'addBuyState', 'copyBuyState']) $(id).innerHTML = stateHtml;
  document.querySelectorAll('[data-about]').forEach(a => a.addEventListener('click', openAbout));
  applyBuyingState();
}

function openAbout(ev) {
  ev?.preventDefault();
  if (!$('home').hidden) { /* already on home */ } else { go('./'); }
  setTimeout(() => { $('aboutPrices').open = true; $('aboutPrices').scrollIntoView({ block: 'start' }); }, 50);
}
$('priceChip').addEventListener('click', openAbout);

function applyBuyingState() {
  const ok = createMix?.valid();
  $('btnCreate').disabled = !buyingOpen || !ok;
  $('btnQuote').disabled = !buyingOpen || !ok;
  if (current) {
    const canAdd = buyingOpen && !current.legacy && current.exists;
    $('btnAdd').disabled = !canAdd;
    $('btnAddQuote').disabled = !canAdd;
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
    <p><strong>What they protect.</strong> Each stock you buy must arrive within ${esc(floorPct)} of its reference price. The pool's
      fee and the price movement your own purchase causes both count against that, and a purchase that would fall short is refused
      before any money moves.</p>
    <p><strong>What they cannot protect.</strong> Because the reference comes from the pool itself, it cannot tell you whether the pool
      is fairly priced. Today the testnet TSLA pool trades about 25% below Chainlink's mainnet TSLA price, and a purchase here would
      still go through. Only an independent price can catch that. The project's mainnet-fork test checks every purchase against
      Chainlink's independent mainnet feeds, and refuses the ones that fall short.</p>
    <p>Taking tokens out and handing baskets on never use these prices, so they work even when every price has expired.</p>`
    : `<p>These are demo prices on the local chain; only the local deployer can change them. Each expires after ${esc(life)}, and buying is
      refused once any has. Each stock you buy must arrive within ${esc(floorPct)} of them. Taking tokens out never needs a price.</p>`;
}

// ------------------------------------------------------------------ wallet ---

async function refreshWallet(openIfNeeded) {
  if (!connected()) { $('walletChip').hidden = true; return; }
  const addr = account().address;
  const reads = [
    pub.getBalance({ address: addr }),
    pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }),
    pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'allowance', args: [addr, D.basket] }),
    D.legacyBasket ? pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'allowance', args: [addr, D.legacyBasket] }) : 0n,
  ];
  const [eth, bal, allowV2, allowV1] = await Promise.all(reads);
  const ethOk = isLocal || eth >= 20_000_000_000_000n;
  const usdOk = bal >= 10_000000n;

  $('gasBal').textContent = isLocal ? '' : `You have ${Number(formatUnits(eth, 18)).toLocaleString(NUM, { maximumFractionDigits: 6 })} test ETH.`;
  $('ckGas').dataset.done = String(ethOk);
  $('ckGas').hidden = isLocal;
  $('usdBal').textContent = `You have ${usdg(bal)} ${stableSym()}.`;
  $('ckUsd').dataset.done = String(usdOk);

  // A standing permission is shown so it can be removed. Version 1 of this page
  // once asked for an open-ended one; the current page asks for exact amounts.
  const leftover = [];
  if (allowV1 > 0n) leftover.push({ spender: D.legacyBasket, amount: allowV1, label: 'the version-1 basket contract' });
  if (allowV2 > 0n) leftover.push({ spender: D.basket, amount: allowV2, label: 'the basket contract' });
  pendingRevoke = leftover[0] || null;
  $('ckAllow').hidden = !pendingRevoke;
  if (pendingRevoke) {
    const amt = pendingRevoke.amount >= 2n ** 128n ? 'an unlimited amount of' : `up to ${usdg(pendingRevoke.amount)}`;
    $('allowText').textContent = `${pendingRevoke.label[0].toUpperCase()}${pendingRevoke.label.slice(1)} may still take ${amt} ${stableSym()} from this wallet when you buy. `
      + 'It can only use it in a purchase you sign, but you can set it to zero now.';
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
let pendingRevoke = null;

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
  const { spender, label } = pendingRevoke;
  const btn = $('btnRevoke'); busy(btn, true, 'Removing…');
  try {
    tx('walletTx', 'signing', 'Confirm in your wallet: this sets the permission to zero…');
    const hash = await send({ address: D.usdg, abi: ERC20_ABI, functionName: 'approve', args: [spender, 0n] });
    tx('walletTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    const left = await pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'allowance', args: [account().address, spender] });
    tx('walletTx', left === 0n ? 'confirmed' : 'failed', left === 0n ? `Removed: ${label} can take 0 from this wallet` : `Still allowed: ${usdg(left)}`, hash);
    log(`removed the permission for ${label} (now ${usdg(left)})`, left === 0n ? 'ok' : 'err', hash);
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

/// Every live basket of both versions, with holdings and plan.
async function loadBaskets() {
  const out = [];
  // Version 2 publishes its id range.
  const next = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'nextTokenId' });
  const ids = []; for (let i = firstV2; i < next; i++) ids.push(i);
  const owners = await readMany(ids.map(id => ({ address: D.basket, abi: BASKET_ABI, functionName: 'ownerOf', args: [id] })));
  const live = ids.filter((_, i) => owners[i]);
  const liveOwners = owners.filter(Boolean);
  const per = ['holdingsOf', 'allocationOf', 'fundingCount', 'totalFunded', 'allocationVersion'];
  const data = await readMany(live.flatMap(id => per.map(f => ({ address: D.basket, abi: BASKET_ABI, functionName: f, args: [id] }))));
  live.forEach((id, i) => {
    const [h, plan, count, funded, version] = data.slice(i * per.length, (i + 1) * per.length);
    out.push({ id, legacy: false, exists: true, owner: liveOwners[i], assets: h[0], amounts: h[1], plan, count: Number(count), funded, version });
  });

  // Version 1 has no id counter: probe in batches until one comes back empty.
  if (D.legacyBasket) {
    for (let start = 1n; start < firstV2; start += 20n) {
      const batch = Array.from({ length: 20 }, (_, i) => start + BigInt(i)).filter(i => i < firstV2);
      const o = await readMany(batch.map(id => ({ address: D.legacyBasket, abi: LEGACY_ABI, functionName: 'ownerOf', args: [id] })));
      const alive = batch.filter((_, i) => o[i]);
      if (!alive.length) break;
      const aliveOwners = o.filter(Boolean);
      const d = await readMany(alive.flatMap(id => [
        { address: D.legacyBasket, abi: LEGACY_ABI, functionName: 'holdingsOf', args: [id] },
        { address: D.legacyBasket, abi: LEGACY_ABI, functionName: 'allocationOf', args: [id] },
      ]));
      alive.forEach((id, i) => out.push({ id, legacy: true, exists: true, owner: aliveOwners[i], assets: d[2 * i][0], amounts: d[2 * i][1], plan: d[2 * i + 1], count: null, funded: null }));
    }
  }
  baskets = out;
}

const totalValue = b => b.assets.reduce((s, a, i) => s + valueOf(a, b.amounts[i]), 0);

/** Render a ribbon. parts: [{ asset, weight }] - weight in any unit, shares are relative. */
function ribbon(hostId, parts, { legend = true, legendFmt = null } = {}) {
  const host = $(hostId);
  const total = parts.reduce((s, p) => s + p.weight, 0);
  host.className = host.className.replace(/\bempty\b/, '').trim();
  if (!total) { host.innerHTML = ''; host.classList.add('empty'); return; }
  const segs = parts.filter(p => p.weight > 0);
  host.innerHTML = segs.map(p => `<span class="seg" style="--c:${colorOf(p.asset)}" data-w="${(100 * p.weight / total).toFixed(3)}"
    title="${esc(symOf(p.asset))} ${(100 * p.weight / total).toFixed(0)}%"></span>`).join('');
  // Next frame, so the width change animates from zero on first paint.
  requestAnimationFrame(() => host.querySelectorAll('.seg').forEach(s => { s.style.width = `calc(${s.dataset.w}% - 4px)`; }));
  if (legend) {
    let lg = host.nextElementSibling;
    if (!lg || !lg.classList.contains('legend')) { lg = document.createElement('div'); lg.className = 'legend'; host.after(lg); }
    lg.innerHTML = segs.map(p => `<span style="--c:${colorOf(p.asset)}"><i></i>${esc(symOf(p.asset))} ${legendFmt ? legendFmt(p) : (100 * p.weight / total).toFixed(0) + '%'}</span>`).join('');
  }
}

function cardHtml(b, { hero = false } = {}) {
  const mine = isMine(b);
  const holds = b.assets.map((a, i) => `<b>${esc(symOf(a))}</b> ${tok(b.amounts[i])}`).join(' · ') || 'Holds nothing';
  const val = totalValue(b);
  const tags = [b.legacy ? '<span class="tag tag-v1">Version 1</span>' : '', !b.legacy && b.count > 1 ? `<span class="tag tag-gift">Added to ${b.count - 1}×</span>` : ''].join(' ');
  const rid = `rb-${hero ? 'hero-' : ''}${b.legacy ? 'v1-' : ''}${b.id}`;
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
    const rid = `rb-${hero ? 'hero-' : ''}${b.legacy ? 'v1-' : ''}${b.id}`;
    if ($(rid)) ribbon(rid, b.assets.map((a, i) => ({ asset: a, weight: valueOf(a, b.amounts[i]) || Number(formatUnits(b.amounts[i], 18)) })), { legend: false });
  }
}

function renderHome() {
  const withHoldings = baskets.filter(b => b.assets.length);
  // The hero shows a real basket: the version-2 one added to most, else the largest.
  const featured = [...withHoldings].sort((x, y) => (Number(!y.legacy) - Number(!x.legacy)) || ((y.count || 0) - (x.count || 0)) || (totalValue(y) - totalValue(x)))[0];
  $('heroCard').innerHTML = featured ? cardHtml(featured, { hero: true }) : '<div class="empty-state"><p><strong>No baskets yet.</strong></p><p>Start the first one below.</p></div>';
  if (featured) paintCardRibbons([featured], true);

  const mine = connected() ? baskets.filter(isMine) : [];
  $('mine').hidden = !connected();
  $('mineCount').textContent = mine.length ? `${mine.length} basket${mine.length > 1 ? 's' : ''}` : '';
  $('myCards').innerHTML = mine.length
    ? mine.map(b => cardHtml(b)).join('')
    : `<div class="empty-state"><p><strong>You do not own a basket yet.</strong></p><p>Start one below, or open someone's basket and copy its plan.</p></div>`;
  paintCardRibbons(mine);

  const others = baskets.filter(b => !isMine(b)).sort((x, y) => (Number(x.legacy) - Number(y.legacy)) || Number(y.id - x.id));
  $('allCards').innerHTML = others.length ? others.map(b => cardHtml(b)).join('') : '<div class="empty-state"><p>No other baskets yet.</p></div>';
  paintCardRibbons(others);
}

// ------------------------------------------------------------- mix editor ---

let createMix = null;
let planMix = null;

/// Rows of stock + share, each a slider and a number, with a live total.
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
      // Two stocks: moving one moves the other, so the mix always adds up.
      if (rows.length === 2) rows[1 - i].pct = 100 - rows[i].pct;
      host.querySelectorAll('input').forEach(x => { if (x !== ev.target) x.value = rows[Number(x.dataset.i)].pct; });
      if (ev.target.type === 'range') host.querySelector(`input[type=number][data-i="${i}"]`).value = rows[i].pct;
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

function quoteHtml(amount, assets, ins, refs, floors, unspent) {
  const lines = assets.map((a, i) => `<dt>${esc(symOf(a))}: ${usdg(ins[i])} ${esc(stableSym())}</dt>
    <dd>about ${tok(refs[i])}<span class="least">at least ${tok(floors[i])}</span></dd>`).join('');
  return `<dl><dt>You pay</dt><dd>${usdg(amount)} ${esc(stableSym())}</dd><div class="sep"></div>${lines}
    <div class="sep"></div><dt>Returned to you</dt><dd>${usdg(unspent)} ${esc(stableSym())}</dd>
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
  } catch (e) { e.plain ? showMsg('createMsg', 'warn', e.plain) : showError('createMsg', e); }
  finally { busy(btn, false); applyBuyingState(); }
});

$('btnCreate').addEventListener('click', async () => {
  clearMsg('createMsg');
  if (needWallet('createMsg')) return;
  const btn = $('btnCreate'); busy(btn, true, 'Creating…');
  try {
    const amount = parseAmount('fund');
    await ensureAllowance(amount, 'createTx');
    tx('createTx', 'signing', 'Buying your stocks: confirm in your wallet…');
    const hash = await send({ address: D.basket, abi: BASKET_ABI, functionName: 'create', args: [createMix.allocation(), amount, await deadline()] });
    tx('createTx', 'pending', 'Waiting for confirmation…', hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    const made = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'BasketCreated' })[0];
    tx('createTx', 'confirmed', `Basket #${made?.args.tokenId ?? ''} is yours`, hash);
    log(`created basket #${made?.args.tokenId}`, 'ok', hash);
    await refreshWallet(false);
    await loadBaskets();
    if (made) go(`?basket=${made.args.tokenId}`);
  } catch (e) {
    tx('createTx', 'failed', 'Cancelled: nothing was spent');
    e.plain ? showMsg('createMsg', 'warn', e.plain) : showError('createMsg', e);
  } finally { busy(btn, false); applyBuyingState(); }
});

// ------------------------------------------------------------ one basket ----

const contractOf = b => (b.legacy ? D.legacyBasket : D.basket);
const abiOf = b => (b.legacy ? LEGACY_ABI : BASKET_ABI);

async function readBasket(id) {
  const legacy = id < firstV2;
  if (legacy && !D.legacyBasket) return null;
  const address = legacy ? D.legacyBasket : D.basket;
  const abi = legacy ? LEGACY_ABI : BASKET_ABI;
  const owner = await pub.readContract({ address, abi, functionName: 'ownerOf', args: [id] }).catch(() => null);
  const b = { id, legacy, owner, exists: !!owner, assets: [], amounts: [], plan: [], count: null, funded: null, version: null };
  if (!owner) return b;
  const [h, plan] = await Promise.all([
    pub.readContract({ address, abi, functionName: 'holdingsOf', args: [id] }),
    pub.readContract({ address, abi, functionName: 'allocationOf', args: [id] }),
  ]);
  Object.assign(b, { assets: h[0], amounts: h[1], plan });
  if (!legacy) {
    const [count, funded, version] = await Promise.all(['fundingCount', 'totalFunded', 'allocationVersion']
      .map(f => pub.readContract({ address, abi, functionName: f, args: [id] })));
    Object.assign(b, { count: Number(count), funded, version });
  }
  return b;
}

/// An outcome that changes what the viewer can do (a hand-over, a closing) is
/// shown above the basket, not inside a panel that is about to disappear.
let pendingNotice = null;

async function showBasket(id) {
  const b = await readBasket(id);
  current = b;
  if (pendingNotice) { showMsg('bvNotice', ...pendingNotice); pendingNotice = null; } else clearMsg('bvNotice');
  for (const m of ['addMsg', 'copyMsg', 'outMsg', 'giveMsg', 'planMsg']) clearMsg(m);
  for (const t of ['addTx', 'copyTx', 'outTx', 'giveTx', 'planTx']) $(t).hidden = true;
  $('addQuote').innerHTML = '';

  if (!b) {
    $('bvTitle').textContent = `Basket #${id}`;
    $('bvEyebrow').textContent = 'Not found';
    $('bvOwner').textContent = 'There is no such basket on this network.';
    return;
  }
  const mine = isMine(b);
  document.title = `Basket #${id} · Jayo`;
  $('bvEyebrow').textContent = b.legacy ? 'Basket · version 1' : 'Basket';
  $('bvTitle').textContent = `Basket #${id}`;
  $('bvExplorer').href = `${D.explorer}/token/${contractOf(b)}/instance/${id}`;
  $('bvExplorer').hidden = !D.explorer;
  $('bvOwner').innerHTML = !b.exists
    ? 'This basket has been <b>closed</b>: everything in it was taken out.'
    : mine ? '<span class="you">You own this basket.</span>' : `Owned by <b>${addrHtml(b.owner)}</b>`;

  // Holdings, valued at the reference prices.
  const val = totalValue(b);
  $('bvValue').textContent = b.exists && val ? `≈ ${usd(val)} at reference prices` : '';
  ribbon('bvRibbon', b.assets.map((a, i) => ({ asset: a, weight: valueOf(a, b.amounts[i]) || Number(formatUnits(b.amounts[i], 18)) })));
  $('bvRows').innerHTML = b.assets.length ? b.assets.map((a, i) => `<tr style="--c:${colorOf(a)}">
      <td><span class="sym"><i></i>${esc(symOf(a))}</span><span class="name">${esc(META[a.toLowerCase()]?.name || '')}</span></td>
      <td class="num">${tok(b.amounts[i])}</td><td class="num">${usd(valueOf(a, b.amounts[i]))}</td></tr>`).join('')
    : `<tr><td colspan="3" class="muted">${b.exists ? 'It holds nothing.' : 'Closed: it holds nothing and cannot receive anything.'}</td></tr>`;

  // Plan for new money.
  ribbon('bvPlanRibbon', b.plan.map(p => ({ asset: p.asset, weight: Number(p.weightBps) })), { legend: false });
  $('bvPlanText').textContent = b.plan.length ? b.plan.map(p => `${symOf(p.asset)} ${Number(p.weightBps) / 100}%`).join(' · ') : 'No plan: the basket is closed.';
  $('bvPlanVersion').textContent = b.version ? `Version ${b.version}` : '';
  $('bvPlanNote').textContent = b.legacy
    ? 'This is a version-1 basket: nobody can add to it. Its owner can still take tokens out or hand it on, and anyone can start a new basket with this plan.'
    : 'Money added to this basket is split this way. The plan does not change what the basket already holds.';

  // Who can do what.
  const canOwn = b.exists && mine;
  $('tabOut').hidden = !canOwn; $('tabGive').hidden = !canOwn; $('tabPlan').hidden = !canOwn || b.legacy;
  $('tabAdd').hidden = b.legacy || !b.exists;
  $('tabCopy').hidden = !b.plan.length;
  $('ownerOnly').hidden = !b.exists || mine;
  $('ownerOnly').textContent = connected()
    ? `Only its owner, ${short(b.owner)}, can take tokens out, hand it on or change its plan.`
    : 'Connect your wallet. If this basket is yours, you can take tokens out, hand it on or change its plan here.';
  $('addLede').textContent = mine
    ? "Top up your basket. The money is split by the basket's plan and bought into it."
    : "Add money to this basket as a gift. It is split by the basket's plan and bought into it. It belongs to the basket's owner, and you get nothing back.";
  $('btnAdd').textContent = mine ? 'Top up my basket' : 'Add to this basket';

  // Take-out choices.
  // One stock left: "all of it" and "everything" are the same thing, so only
  // the part-way options and the closing one are offered.
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
  resetGive();

  const visible = [...$('bvTabs').querySelectorAll('[role=tab]')].filter(t => !t.hidden);
  const keep = visible.find(t => t.getAttribute('aria-selected') === 'true');
  if (visible.length) selectTab(keep || visible[0]);
  else for (const p of document.querySelectorAll('.bv-actions [role=tabpanel]')) p.hidden = true;
  $('bvActions').hidden = !visible.length;
  applyBuyingState();
  renderHistory(b).catch(() => { $('bvHistory').innerHTML = '<li class="muted">The history could not be read just now.</li>'; });
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

// ----------------------------------------------------------------- history ---

/// Every event a basket contract has emitted since it was deployed. Not cached:
/// the history is read right after a purchase, and a cached block number (viem
/// keeps one for a few seconds) would stop the query one block short of it.
async function contractLogs(address, fromBlock) {
  const raw = await pub.getLogs({ address, fromBlock: BigInt(fromBlock || 0), toBlock: 'latest' });
  return parseEventLogs({ abi: EVENTS, logs: raw, strict: false });
}

async function renderHistory(b) {
  const logs = (await contractLogs(contractOf(b), b.legacy ? D.legacyDeployBlock : D.deployBlock))
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
  const taken = ls => ls.filter(l => l.eventName === 'AssetRedeemed').map(l => amt(l.args.amount, l.args.asset)).join(' and ');
  const cash = v => `${usdg(v)} ${esc(stableSym())}`;

  const items = [];
  for (const [hash, ls] of byTx) {
    const t = times[ls[0].blockNumber];
    const ev = name => ls.find(l => l.eventName === name);
    let cls = '', html = '';
    if (ev('BasketCreated')) {
      const c = ev('BasketCreated'); const copied = ev('AllocationCopied');
      html = `${copied ? `Started from basket #${copied.args.sourceTokenId}'s plan` : 'Created'} by ${who(c.args.creator)} with ${cash(c.args.usdgSpent)}${bought(ls) ? `: bought ${bought(ls)}` : ''}.`;
    } else if (ev('Contributed')) {
      const c = ev('Contributed'); cls = 'add';
      html = `${Who(c.args.contributor)} added ${cash(c.args.usdgSpent)}: bought ${bought(ls)}.`;
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
    const url = txUrl(hash);
    items.push({ t, html: `<li class="${cls}">${html}<span class="when">${new Date(t * 1000).toLocaleString(NUM, { dateStyle: 'medium', timeStyle: 'short' })}${url ? ` · <a href="${url}" target="_blank" rel="noopener noreferrer">receipt</a>` : ''}</span></li>` });
  }
  items.sort((x, y) => y.t - x.t);
  $('bvHistory').innerHTML = items.map(i => i.html).join('') || '<li class="muted">No events found.</li>';
}

// ---------------------------------------------------------------- add money ---

$('addAmt').addEventListener('input', () => { clearMsg('addMsg'); $('addQuote').innerHTML = ''; });

$('btnAddQuote').addEventListener('click', async () => {
  clearMsg('addMsg');
  const btn = $('btnAddQuote'); busy(btn, true, 'Checking…');
  try {
    const amount = parseAmount('addAmt');
    const [ins, refs, floors, unspent] = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'previewContribute', args: [current.id, amount] });
    $('addQuote').innerHTML = quoteHtml(amount, current.plan.map(p => p.asset), ins, refs, floors, unspent);
  } catch (e) { e.plain ? showMsg('addMsg', 'warn', e.plain) : showError('addMsg', e); }
  finally { busy(btn, false); applyBuyingState(); }
});

$('btnAdd').addEventListener('click', async () => {
  clearMsg('addMsg');
  if (needWallet('addMsg')) return;
  const b = current;
  const btn = $('btnAdd'); busy(btn, true, 'Adding…');
  try {
    const amount = parseAmount('addAmt');
    await ensureAllowance(amount, 'addTx');
    tx('addTx', 'signing', `Adding ${formatUnits(amount, 6)} ${stableSym()} to basket #${b.id}: confirm in your wallet…`);
    // The plan version this page showed: if the owner changes the plan first, this reverts.
    const hash = await send({ address: D.basket, abi: BASKET_ABI, functionName: 'contribute', args: [b.id, amount, b.version, await deadline()] });
    tx('addTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    tx('addTx', 'confirmed', `Added to basket #${b.id}`, hash);
    log(`added ${formatUnits(amount, 6)} ${stableSym()} to basket #${b.id}`, 'ok', hash);
    await refreshWallet(false); await loadBaskets(); await showBasket(b.id);
    showMsg('addMsg', 'success', `Added to basket #${b.id}.`, isMine(b) ? 'Your basket holds more now; the table shows exactly what.' : "It now belongs to the basket's owner. The history shows your addition.");
  } catch (e) {
    tx('addTx', 'failed', 'Cancelled: nothing was spent');
    if (decode(e)?.name === 'AllocationChangedSinceQuote') await showBasket(b.id);
    e.plain ? showMsg('addMsg', 'warn', e.plain) : showError('addMsg', e);
  } finally { busy(btn, false); applyBuyingState(); }
});

// -------------------------------------------------------------------- copy ---

$('btnCopy').addEventListener('click', async () => {
  clearMsg('copyMsg');
  if (needWallet('copyMsg')) return;
  const b = current;
  const btn = $('btnCopy'); busy(btn, true, 'Buying…');
  try {
    const amount = parseAmount('copyAmt');
    await ensureAllowance(amount, 'copyTx');
    tx('copyTx', 'signing', 'Buying your basket with this plan: confirm in your wallet…');
    // Version 2 copies natively (and records where the plan came from). A
    // version-1 plan is copied by creating a new version-2 basket with it.
    const hash = b.legacy
      ? await send({ address: D.basket, abi: BASKET_ABI, functionName: 'create', args: [b.plan.map(p => ({ asset: p.asset, weightBps: Number(p.weightBps) })), amount, await deadline()] })
      : await send({ address: D.basket, abi: BASKET_ABI, functionName: 'copyAllocation', args: [b.id, amount, b.version, await deadline()] });
    tx('copyTx', 'pending', 'Waiting for confirmation…', hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    const made = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'BasketCreated' })[0];
    tx('copyTx', 'confirmed', `Basket #${made?.args.tokenId} is yours`, hash);
    log(`started basket #${made?.args.tokenId} with basket #${b.id}'s plan`, 'ok', hash);
    await refreshWallet(false); await loadBaskets();
    if (made) go(`?basket=${made.args.tokenId}`);
  } catch (e) {
    tx('copyTx', 'failed', 'Cancelled: nothing was spent');
    e.plain ? showMsg('copyMsg', 'warn', e.plain) : showError('copyMsg', e);
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
    const address = contractOf(b), abi = abiOf(b);
    const before = await pub.readContract({ address, abi, functionName: 'holdingsOf', args: [b.id] });
    tx('outTx', 'signing', 'Sending the tokens to your wallet: confirm in your wallet…');
    const hash = kind === 'asset' ? await send({ address, abi, functionName: 'redeemAsset', args: [b.id, value] })
      : kind === 'frac' ? await send({ address, abi, functionName: 'redeemFraction', args: [b.id, Number(value)] })
      : await send({ address, abi, functionName: 'redeem', args: [b.id] });
    tx('outTx', 'pending', 'Waiting for confirmation…', hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    const sent = parseEventLogs({ abi: EVENTS, logs: receipt.logs, eventName: 'AssetRedeemed' })
      .map(l => `${tok(l.args.amount)} ${symOf(l.args.asset)}`).join(' and ');
    const closed = parseEventLogs({ abi: EVENTS, logs: receipt.logs }).some(l => l.eventName === 'PositionClosed' || l.eventName === 'BasketRedeemed')
      || before[0].length === 0;
    tx('outTx', 'confirmed', 'Sent to your wallet', hash);
    log(`took ${sent} out of basket #${b.id}`, 'ok', hash);
    if (closed) pendingNotice = ['success', `Sent ${sent || 'the tokens'} to your wallet.`, 'That was the last of it, so the basket is closed. Its history stays readable here.'];
    await refreshWallet(false); await loadBaskets(); await showBasket(b.id);
    if (!closed) showMsg('outMsg', 'success', `Sent ${sent || 'the tokens'} to your wallet.`, 'The basket is still yours and holds the rest. No price was needed for this.');
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
  const known = [D.basket, D.legacyBasket, D.usdg, D.gateway, D.policy, D.adapter, D.poolManager, D.renderer, ...(D.stocks || [])]
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
    const hash = await send({ address: contractOf(b), abi: abiOf(b), functionName: 'safeTransferFrom', args: [account().address, to, b.id] });
    tx('giveTx', 'pending', 'Waiting for confirmation…', hash);
    await pub.waitForTransactionReceipt({ hash });
    tx('giveTx', 'confirmed', 'Handed on', hash);
    log(`handed basket #${b.id} to ${short(to)}`, 'ok', hash);
    pendingNotice = ['success', `Basket #${b.id} now belongs to ${short(to)}.`,
      "You can no longer take tokens out of it or hand it on. Send them this page's link (Copy link, above) so they can see exactly what they received."];
    await loadBaskets(); await showBasket(b.id);
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
    await loadBaskets(); await showBasket(b.id);
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
  showMsg('demoMsg', 'warn', 'Prices are now two days old.', 'Buying refuses. Taking tokens out of a basket you own still works.');
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
