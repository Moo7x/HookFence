// Stage 2: for each sampled transaction, work out who traded what, at what
// price, and compare with Chainlink (last update before the block) and with the
// deepest USDG pool's mid price just before the transaction.
import { rpc, batch, pad, PM, TRANSFER, SWAP } from './rpc.mjs';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const IN = process.env.IN || 'sample1.json';
const S = JSON.parse(readFileSync(IN));
const INIT = '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';
const USEROP = '0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f';
const ANSWER = '0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f';
const ZERO = '0x0000000000000000000000000000000000000000';
const USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';
const FEEDS = {
  TSLA: '0x4A1166a659A55625345e9515b32adECea5547C38', NVDA: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15',
  AAPL: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0', AMZN: '0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C',
  GOOGL: '0xF6f373a037c30F0e5010d854385cA89185AE638b', QQQ: '0x80901d846d5D7B030F26B480776EE3b29374C2ae',
  ETH: '0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9', USDC: '0x9e6f4605992a899eE2999999F3Ec80C41F452546',
  USDG: '0x61B7e5650328764B076A108EFF5fa7282a1B9aD2',
};
const stockBy = Object.fromEntries(Object.entries(S.tokens).map(([k, v]) => [v.toLowerCase(), k]));
const int = (hex, bits) => { let v = BigInt('0x' + hex); if (v >> BigInt(bits - 1)) v -= 1n << BigInt(bits); return v; };

// ---------- pool keys for every pool id seen
const cacheFile = 'pools.json';
const pools = existsSync(cacheFile) ? JSON.parse(readFileSync(cacheFile)) : {};
const ids = new Set();
for (const tx of S.txs) for (const l of tx.logs) if (l.topics[0] === SWAP && l.address.toLowerCase() === PM) ids.add(l.topics[1]);
const missing = [...ids].filter(i => !pools[i]);
for (let i = 0; i < missing.length; i += 15) {
  const chunk = missing.slice(i, i + 15);
  const res = [];
  for (const id of chunk) res.push(await rpc('eth_getLogs', [{ address: PM, fromBlock: '0x0', toBlock: 'latest', topics: [INIT, id] }]));
  chunk.forEach((id, k) => {
    const l = res[k]?.[0];
    if (!l) { pools[id] = { unknown: true }; return; }
    const d = l.data.slice(2);
    pools[id] = { c0: '0x' + l.topics[2].slice(26), c1: '0x' + l.topics[3].slice(26), fee: parseInt(d.slice(0, 64), 16),
      spacing: Number(int(d.slice(64, 128), 256)), hooks: '0x' + d.slice(152, 192) };
  });
  process.stderr.write(`pool keys ${Math.min(i + 15, missing.length)}/${missing.length}\n`);
}
writeFileSync(cacheFile, JSON.stringify(pools));

// ---------- token metadata (symbol, decimals) for every currency seen
const metaFile = 'tokens.json';
const meta = existsSync(metaFile) ? JSON.parse(readFileSync(metaFile)) : {};
meta[ZERO] = { sym: 'ETH', dec: 18 };
const cur = new Set();
for (const p of Object.values(pools)) if (!p.unknown) { cur.add(p.c0); cur.add(p.c1); }
for (const tx of S.txs) for (const l of tx.logs) if (l.topics[0] === TRANSFER && l.topics.length === 3) cur.add(l.address.toLowerCase());
const needMeta = [...cur].filter(c => !meta[c]);
const decodeStr = h => { try { if (!h || h === '0x') return '?'; const b = Buffer.from(h.slice(2), 'hex');
  if (b.length === 32) return b.toString('utf8').replace(/\0/g, ''); const len = Number(BigInt('0x' + h.slice(66, 130))); return b.slice(64, 64 + len).toString('utf8'); } catch { return '?'; } };
for (let i = 0; i < needMeta.length; i += 20) {
  const chunk = needMeta.slice(i, i + 20);
  const syms = [], decs = [];
  for (const a of chunk) { syms.push(await rpc('eth_call', [{ to: a, data: '0x95d89b41' }, 'latest']).catch(() => null)); decs.push(await rpc('eth_call', [{ to: a, data: '0x313ce567' }, 'latest']).catch(() => null)); }
  chunk.forEach((a, k) => { meta[a] = { sym: typeof syms[k] === 'string' ? decodeStr(syms[k]) : '?', dec: typeof decs[k] === 'string' && decs[k] !== '0x' ? parseInt(decs[k], 16) : 18 }; });
}
writeFileSync(metaFile, JSON.stringify(meta));

// ---------- uiMultiplier per stock (current; corporate actions in the window are rare)
const mult = {};
for (const [sym, a] of Object.entries(S.tokens)) mult[sym] = Number(BigInt(await rpc('eth_call', [{ to: a, data: '0xa60bf13d' }, 'latest']))) / 1e18;

// ---------- Chainlink history via AnswerUpdated on the current aggregator
const firstBlock = Math.min(...S.txs.map(t => t.block));
const clHist = {};
for (const [sym, proxy] of Object.entries(FEEDS)) {
  const agg = '0x' + (await rpc('eth_call', [{ to: proxy, data: '0x245a7bfc' }, 'latest'])).slice(26);
  const from = firstBlock - 3 * 864000; // 3 days of lead-in for weekends
  const logs = [];
  for (let b = from; b <= S.head; b += 2_000_000) {
    const r = await rpc('eth_getLogs', [{ address: agg, fromBlock: '0x' + b.toString(16), toBlock: '0x' + Math.min(S.head, b + 1_999_999).toString(16), topics: [ANSWER] }]);
    logs.push(...r);
  }
  clHist[sym] = logs.map(l => ({ block: parseInt(l.blockNumber, 16), price: Number(int(l.topics[1].slice(2), 256)) / 1e8, ts: Number(BigInt(l.data)) }));
}
const clAt = (sym, block) => { const h = clHist[sym]; let best = null; for (const x of h) { if (x.block < block) best = x; else break; } return best; };

// ---------- the time of a block (interpolated from window stamps)
const stampPts = Object.entries(S.stamps).map(([b, t]) => [Number(b), t]).sort((a, b) => a[0] - b[0]);
const tsOf = b => { let p = stampPts[0]; for (const q of stampPts) if (q[0] <= b) p = q; const near = stampPts.find(q => q[0] >= b) || p; return p[1] + (b - p[0]) / 9.89; };

// ---------- analyse each transaction
const rows = [];
for (const tx of S.txs) {
  if (tx.status !== '0x1') continue;
  const logs = tx.logs;
  let users = [tx.from.toLowerCase()];
  const ops = logs.filter(l => l.topics[0] === USEROP).map(l => '0x' + l.topics[2].slice(26));
  if (ops.length) users = ops;
  const net = {}; // addr -> token -> delta (raw BigInt)
  for (const l of logs) {
    if (l.topics[0] !== TRANSFER || l.topics.length !== 3) continue;
    const tk = l.address.toLowerCase(), f = '0x' + l.topics[1].slice(26), t = '0x' + l.topics[2].slice(26), v = BigInt(l.data === '0x' ? 0 : l.data);
    (net[f] ??= {})[tk] = (net[f][tk] || 0n) - v;
    (net[t] ??= {})[tk] = (net[t][tk] || 0n) + v;
  }
  // native ETH paid in
  const swaps = logs.filter(l => l.topics[0] === SWAP && l.address.toLowerCase() === PM).map(l => {
    const d = l.data.slice(2);
    return { id: l.topics[1], sender: '0x' + l.topics[2].slice(26), a0: int(d.slice(0, 64), 256), a1: int(d.slice(64, 128), 256),
      sqrtP: BigInt('0x' + d.slice(128, 192)), liq: BigInt('0x' + d.slice(192, 256)), fee: parseInt(d.slice(320, 384), 16) };
  });
  const uxFill = logs.find(l => l.topics[0] === '0x78ad7ec0e9f89e74012afa58738b6b661c024cb0fd185ee2f616c0a28924bd66');
  if (uxFill) users = ['0x' + uxFill.topics[3].slice(26)];
  const lp = logs.some(l => l.topics[0] === '0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec');
  // The user: the address outside the PoolManager and pool hooks with the
  // largest Stock Token change (relayers and smart accounts mean it is often
  // not tx.from). Falls back to tx.from / UserOp senders.
  const hookSet = new Set(Object.values(pools).filter(p => !p.unknown).map(p => p.hooks));
  const cands = Object.entries(net).filter(([a, d]) => a !== PM && !hookSet.has(a) && Object.entries(d).some(([tk, v]) => stockBy[tk] && v !== 0n))
    .map(([a, d]) => [a, Object.entries(d).filter(([tk]) => stockBy[tk]).reduce((m, [, v]) => (v < 0n ? -v : v) > m ? (v < 0n ? -v : v) : m, 0n)])
    .sort((x, y) => (y[1] > x[1] ? 1 : -1));
  if (cands.length && !uxFill) users = [cands[0][0]];
  for (const u of users) {
    const d = net[u] || {};
    const stockLegs = Object.entries(d).filter(([tk, v]) => stockBy[tk] && v !== 0n);
    if (stockLegs.length !== 1) { rows.push({ hash: tx.hash, kind: stockLegs.length ? 'multi-stock' : (lp ? 'lp' : 'no-user-stock-delta'), to: tx.to, block: tx.block }); continue; }
    const [stk, sraw] = stockLegs[0];
    const sym = stockBy[stk];
    const shares = Number(sraw) / 1e18 * mult[sym];
    // counter-legs in known USD assets
    let usd = 0, legs = [], unknown = [];
    for (const [tk, v] of Object.entries(d)) {
      if (tk === stk || v === 0n) continue;
      const m = meta[tk] || { sym: '?', dec: 18 };
      const amt = Number(v) / 10 ** m.dec;
      if (tk === USDG) { usd += amt; legs.push('USDG'); }
      else if (/^USDC/.test(m.sym)) { usd += amt; legs.push(m.sym); }
      else if (/^WETH$/.test(m.sym)) { const e = clAt('ETH', tx.block); usd += amt * e.price; legs.push('WETH'); }
      else unknown.push(m.sym);
    }
    const val = BigInt(tx.value || '0x0');
    if (val > 0n && u === tx.from.toLowerCase()) { usd -= Number(val) / 1e18 * clAt('ETH', tx.block).price; legs.push('ETH-in'); }
    // native ETH received: net ETH swap delta across ETH pools (router perspective), only if no other counter-leg
    if (!legs.length && !unknown.length) {
      let eth = 0n;
      for (const s of swaps) { const p = pools[s.id]; if (!p || p.unknown) continue; if (p.c0 === ZERO) eth += s.a0; }
      if (eth > 0n) { usd += Number(eth) / 1e18 * clAt('ETH', tx.block).price; legs.push('ETH-out(swap-event)'); }
    }
    const kind = unknown.length ? 'unpriced-counter' : !legs.length ? 'no-counter' : (sraw > 0n && usd < 0 ? 'BUY' : sraw < 0n && usd > 0 ? 'SELL' : 'odd');
    const cl = clAt(sym, tx.block);
    const px = Math.abs(usd / shares);
    const bpsVsCL = cl ? (kind === 'BUY' ? (px / cl.price - 1) : (1 - px / cl.price)) * 1e4 : null; // + = user paid more / got less than Chainlink
    rows.push({ hash: tx.hash, block: tx.block, ts: tsOf(tx.block), to: tx.to, sel: tx.input4, user: u, aa: ops.length > 0, kind, sym, shares, usd, px,
      cl: cl?.price, clAgeS: cl ? tsOf(tx.block) - cl.ts : null, bpsVsCL, ux: !!uxFill, legs: legs.join('+'), unknown: unknown.join('+'), nSwaps: swaps.length,
      pools: swaps.map(s => s.id), hooked: swaps.some(s => pools[s.id]?.hooks && pools[s.id].hooks !== ZERO), maxFee: Math.max(0, ...swaps.map(s => s.fee)),
      gasUsd: Number(BigInt(tx.gasUsed) * BigInt(tx.effectiveGasPrice)) / 1e18 * (clAt('ETH', tx.block)?.price || 0) });
  }
}
writeFileSync(IN.replace('.json', '.rows.json'), JSON.stringify(rows, null, 0));
writeFileSync(IN.replace('.json', '.cl.json'), JSON.stringify(clHist));
const by = {}; rows.forEach(r => by[r.kind] = (by[r.kind] || 0) + 1);
console.log('kinds', by);
console.log('multipliers', mult);
console.log('chainlink updates in range', Object.fromEntries(Object.entries(clHist).map(([k, v]) => [k, v.length])));
