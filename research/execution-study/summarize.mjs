// Tables for docs/EXECUTION_STUDY.md from the analysed samples.
//   node summarize.mjs sample7d.rows.json sampleRTH.rows.json
import { readFileSync } from 'node:fs';
const files = process.argv.slice(2);
const all = files.flatMap(f => JSON.parse(readFileSync(f)).map(x => ({ ...x, src: f })));
const kinds = {}; all.forEach(x => kinds[x.kind] = (kinds[x.kind] || 0) + 1);
// Audited by hand: a three-party multicall (liquidity/vault accounting), not a trade.
const EXCLUDE = new Set(['0x329f2f8c100e75a4d0db9c54a358fddee31026c8ba051bfb06945ea835a40303']);
const t = all.filter(x => !EXCLUDE.has(x.hash) && (x.kind === 'BUY' || x.kind === 'SELL') && x.bpsVsCL != null && Math.abs(x.usd) >= 1);
const state = ts => { const d = new Date((ts - 4 * 3600) * 1000); const wd = d.getUTCDay(), m = d.getUTCHours() * 60 + d.getUTCMinutes();
  if (wd === 6 || (wd === 0 && m < 20 * 60) || (wd === 5 && m >= 20 * 60)) return 'weekend';
  if (wd >= 1 && wd <= 5 && m >= 570 && m < 960) return 'regular'; return 'extended'; };
const med = a => { if (!a.length) return '-'; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)].toFixed(0); };
const vw = a => { const v = a.reduce((s, x) => s + Math.abs(x.usd), 0); return v ? (a.reduce((s, x) => s + Math.abs(x.usd) * x.bpsVsCL, 0) / v).toFixed(1) : '-'; };
console.log('classification of all sampled transactions:', kinds);
console.log('priced user trades >= $1:', t.length);

// strict peer: >= same size, same token and side, within 300 blocks (~30 s)
for (const x of t) {
  const peers = t.filter(y => y !== x && y.sym === x.sym && y.kind === x.kind && Math.abs(y.block - x.block) <= 300 && Math.abs(y.usd) >= Math.abs(x.usd));
  x.peerGap = peers.length ? x.bpsVsCL - Math.min(...peers.map(p => p.bpsVsCL)) : null;
}

const buckets = [[1, 100], [100, 1000], [1000, 10000], [10000, 1e12]];
console.log('\n| Session | Size | Trades | Volume | Median bps vs Chainlink, buys / sells | Vol-weighted bps | With a peer | Worse than peer by >25 bps | Observed difference vs peers |');
console.log('|---|---|---|---|---|---|---|---|---|');
for (const st of ['regular', 'extended', 'weekend']) for (const [lo, hi] of buckets) {
  const a = t.filter(x => state(x.ts) === st && Math.abs(x.usd) >= lo && Math.abs(x.usd) < hi); if (!a.length) continue;
  const p = a.filter(x => x.peerGap != null);
  const diff = p.reduce((s, x) => s + Math.max(0, x.peerGap) * Math.abs(x.usd) / 1e4, 0), pv = p.reduce((s, x) => s + Math.abs(x.usd), 0);
  console.log(`| ${st} | $${lo}–${hi >= 1e12 ? '∞' : hi} | ${a.length} | $${a.reduce((s, x) => s + Math.abs(x.usd), 0).toFixed(0)} | ${med(a.filter(x => x.kind === 'BUY').map(x => x.bpsVsCL))} / ${med(a.filter(x => x.kind === 'SELL').map(x => x.bpsVsCL))} | ${st === 'weekend' ? 'n/a (feed frozen)' : vw(a)} | ${p.length} | ${p.filter(x => x.peerGap > 25).length} | $${diff.toFixed(2)} (${pv ? (diff / pv * 1e4).toFixed(1) : '-'} bps) |`);
}
const p = t.filter(x => x.peerGap != null), diff = p.reduce((s, x) => s + Math.max(0, x.peerGap) * Math.abs(x.usd) / 1e4, 0);
console.log(`\nall sessions: ${p.length} trades with a peer, $${p.reduce((s, x) => s + Math.abs(x.usd), 0).toFixed(0)} volume, observed difference $${diff.toFixed(2)}; largest single $${Math.max(...p.map(x => Math.max(0, x.peerGap) * Math.abs(x.usd) / 1e4)).toFixed(2)}`);

console.log('\nby token (non-weekend): median buy / sell bps vs Chainlink, n');
for (const s of [...new Set(t.map(x => x.sym))]) { const a = t.filter(x => x.sym === s && state(x.ts) !== 'weekend'); console.log(`  ${s}: ${med(a.filter(x => x.kind === 'BUY').map(x => x.bpsVsCL))} / ${med(a.filter(x => x.kind === 'SELL').map(x => x.bpsVsCL))}  n=${a.length}`); }

console.log('\nrouters (non-weekend, >= 20 trades): median buy / sell bps vs Chainlink');
const rt = {}; t.filter(x => state(x.ts) !== 'weekend').forEach(x => (rt[x.ux ? 'UniswapX fill' : x.to + ' ' + x.sel] ??= []).push(x));
Object.entries(rt).filter(([, a]) => a.length >= 20).sort((a, b) => b[1].length - a[1].length).forEach(([k, a]) => console.log(`  ${k}: ${med(a.filter(x => x.kind === 'BUY').map(x => x.bpsVsCL))} / ${med(a.filter(x => x.kind === 'SELL').map(x => x.bpsVsCL))}  n=${a.length}`));
console.log('UniswapX fills among priced trades:', t.filter(x => x.ux).length);
console.log('median gas per trade $' + med(t.map(x => x.gasUsd * 1000)) + ' /1000');
