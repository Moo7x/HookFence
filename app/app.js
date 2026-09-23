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

import { createPublicClient, createWalletClient, http, parseUnits, formatUnits }
  from 'https://esm.sh/viem@2.21.55';
import { privateKeyToAccount } from 'https://esm.sh/viem@2.21.55/accounts';
import { foundry } from 'https://esm.sh/viem@2.21.55/chains';

const RPC = 'http://127.0.0.1:8545';

// Anvil's deterministic accounts. These keys are published in Foundry's own
// documentation and hold nothing on any real network. A demo that required a
// wallet extension would not survive a recorded walkthrough.
const ACCOUNTS = [
  { label: 'Wallet A', key: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' },
  { label: 'Wallet B', key: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' },
];
const THIRD_PARTY = '0x90F79bf6EB2c4f870365E785982E1f101E93b906';

let acctIndex = 0;
const account = () => privateKeyToAccount(ACCOUNTS[acctIndex].key);

const pub = createPublicClient({ chain: foundry, transport: http(RPC) });
const wallet = () => createWalletClient({ account: account(), chain: foundry, transport: http(RPC) });

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
  { type:'function', name:'setManager', stateMutability:'nonpayable', inputs:[{type:'uint256'},{type:'address'}], outputs:[] },
  { type:'function', name:'positionManager', stateMutability:'view', inputs:[{type:'uint256'}], outputs:[{type:'address'}] },
  { type:'function', name:'positionVersion', stateMutability:'view', inputs:[{type:'uint256'}], outputs:[{type:'uint64'}] },
  { type:'function', name:'redeem', stateMutability:'nonpayable', inputs:[{type:'uint256'}], outputs:[] },
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
  { type:'error', name:'OutputBelowFloor', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'InputOverspent', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'IntentExpired', inputs:[{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'FeedStale', inputs:[{type:'address'},{type:'uint256'},{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'FeedAnswerNotPositive', inputs:[{type:'address'},{type:'int256'}] },
  { type:'error', name:'OraclePausedForCorporateAction', inputs:[{type:'address'}] },
  { type:'error', name:'CorporateActionPending', inputs:[{type:'address'},{type:'uint256'},{type:'uint256'}] },
  { type:'error', name:'TokenNotSupported', inputs:[{type:'address'}] },
  { type:'error', name:'ERC721InsufficientApproval', inputs:[{type:'address'},{type:'uint256'}] },
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
  { type:'function', name:'latestRoundData', stateMutability:'view', inputs:[],
    outputs:[{type:'uint80'},{type:'int256'},{type:'uint256'},{type:'uint256'},{type:'uint80'}] },
];

// ------------------------------------------------------------ plain words ---

// Each entry turns a contract error into something a person can act on.
// `a` is the decoded argument list.
const PLAIN = {
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

async function boot() {
  try {
    D = await (await fetch('/contracts/reports/jayo-local.json', { cache: 'no-store' })).json();
  } catch {
    $('netmeta').textContent = 'no deployment found — run ./scripts/run-demo.sh';
    log('contracts/reports/jayo-local.json missing. Run the deploy script.', 'err');
    return;
  }

  for (const k of ['aapl', 'nvda', 'usdg']) {
    const [symbol, name] = await Promise.all([
      pub.readContract({ address: D[k], abi: ERC20_ABI, functionName: 'symbol' }),
      pub.readContract({ address: D[k], abi: ERC20_ABI, functionName: 'name' }),
    ]);
    META[D[k].toLowerCase()] = { symbol, name: name.replace(' [MOCK]', '') };
  }
  ASSETS = [D.aapl, D.nvda];
  minLeg = await pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'minLegInput' });

  rows = [{ asset: D.aapl, pct: 60 }, { asset: D.nvda, pct: 40 }];
  renderRows();

  $('toAddr').value = ACCOUNTS[1].key ? privateKeyToAccount(ACCOUNTS[1].key).address : THIRD_PARTY;

  $('led').classList.add('on');
  await refreshStatus();
  await loadPositions();
  log('connected — all assets are mocks on a local chain', 'ok');
}

async function refreshStatus() {
  const [bn, bal] = await Promise.all([
    pub.getBlockNumber(),
    pub.readContract({ address: D.usdg, abi: ERC20_ABI, functionName: 'balanceOf', args: [account().address] }),
  ]);
  $('netmeta').textContent =
    `local chain ${D.chainId} · block ${bn} · ${ACCOUNTS[acctIndex].label} ${short(account().address)} · ${usdg(bal)} USDG`;
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
  const [owner, manager] = await Promise.all([
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'ownerOf', args: [BigInt(id)] }),
    pub.readContract({ address: D.basket, abi: BASKET_ABI, functionName: 'positionManager', args: [BigInt(id)] }),
  ]);
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

  $('detailNotes').innerHTML = manager !== '0x0000000000000000000000000000000000000000'
    ? `<div class="msg info"><span class="icon">i</span><div class="body">
         <strong>${esc(short(manager))} can manage this basket.</strong><br>
         They cannot take the tokens out — only the owner can. Handing the basket over removes them automatically.</div></div>`
    : '';

  ['btnTransfer', 'btnRedeem', 'btnManager'].forEach(b => { $(b).disabled = !mine; });
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

// ------------------------------------------------------- transfer / manager -

$('btnManager').addEventListener('click', async () => {
  clearMsg('transferMsg');
  const btn = $('btnManager'); busy(btn, true, 'Allowing…');
  try {
    tx('transferTx', 'signing', 'Allowing a manager…');
    const hash = await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'setManager', args: [BigInt(selectedId), THIRD_PARTY] });
    tx('transferTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('transferTx', 'confirmed', 'Done');
    showOk('transferMsg', `${short(THIRD_PARTY)} can now manage this basket.`, 'Hand the basket over and watch this permission disappear.');
    await selectPosition(selectedId, true);
  } catch (e) { tx('transferTx', 'failed', 'Cancelled'); showError('transferMsg', e); }
  finally { busy(btn, false); }
});

$('btnTransfer').addEventListener('click', async () => {
  clearMsg('transferMsg');
  const btn = $('btnTransfer'); busy(btn, true, 'Handing over…');
  try {
    const to = $('toAddr').value.trim();
    tx('transferTx', 'signing', 'Handing over the basket…');
    const hash = await wallet().writeContract({ address: D.basket, abi: BASKET_ABI, functionName: 'transferFrom', args: [account().address, to, BigInt(selectedId)] });
    tx('transferTx', 'pending', 'Waiting for confirmation…');
    await pub.waitForTransactionReceipt({ hash });
    tx('transferTx', 'confirmed', 'Done');
    showOk('transferMsg', `Basket #${selectedId} now belongs to ${short(to)}.`,
      'You can no longer withdraw from it, and any manager you allowed has been removed.');
    log(`basket #${selectedId} handed to ${short(to)}`, 'ok');
    await loadPositions();
  } catch (e) { tx('transferTx', 'failed', 'Cancelled'); showError('transferMsg', e); }
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

// ------------------------------------------------------------ demo panel ----

$('btnAcct').addEventListener('click', async () => {
  acctIndex = (acctIndex + 1) % ACCOUNTS.length;
  $('toAddr').value = privateKeyToAccount(ACCOUNTS[(acctIndex + 1) % ACCOUNTS.length].key).address;
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
    const w = wallet();
    for (const [feed, price] of [[D.aaplFeed, 255_00000000n], [D.nvdaFeed, 150_00000000n], [D.usdgFeed, 1_00000000n]]) {
      const h = await w.writeContract({ address: feed, abi: FEED_ABI, functionName: 'setAnswer', args: [price] });
      await pub.waitForTransactionReceipt({ hash: h });
    }
    $('demoMsg').innerHTML = `<div class="msg success"><span class="icon">✓</span><div class="body">
      <strong>Prices are current again.</strong> Buying works.</div></div>`;
    log('feeds refreshed', 'ok');
  } catch (e) { showError('demoMsg', e); }
  finally { busy(btn, false); }
});

$('btnReload').addEventListener('click', async () => { await refreshStatus(); await loadPositions(); log('state reloaded'); });

boot();
