import { readFileSync } from 'node:fs';
const f = process.argv[2] || 'sample7d.rows.json';
const t = JSON.parse(readFileSync(f)).filter(x => (x.kind === 'BUY' || x.kind === 'SELL') && x.bpsVsCL != null && Math.abs(x.usd) >= 1);
const state = ts => { const d = new Date((ts - 4 * 3600) * 1000); const wd = d.getUTCDay(), m = d.getUTCHours() * 60 + d.getUTCMinutes();
  if (wd === 6 || (wd === 0 && m < 20 * 60) || (wd === 5 && m >= 20 * 60)) return 'weekend';
  if (wd >= 1 && wd <= 5 && m >= 570 && m < 960) return 'regular'; return 'extended'; };
// "Worse" = paid more on a buy / received less on a sale, relative to a trade of >= the same size,
// same token and side, within +-300 blocks (~30 s). bpsVsCL is signed so that higher = worse for the user.
let rows = [];
for (const x of t) {
  const peers = t.filter(y => y !== x && y.sym === x.sym && y.kind === x.kind && Math.abs(y.block - x.block) <= 300 && Math.abs(y.usd) >= Math.abs(x.usd));
  if (!peers.length) continue;
  const best = peers.reduce((a, b) => (b.bpsVsCL < a.bpsVsCL ? b : a));
  const gap = x.bpsVsCL - best.bpsVsCL;
  rows.push({ x, best, gap, usdGap: Math.max(0, gap) * Math.abs(x.usd) / 1e4 });
}
const pos = rows.filter(r => r.gap > 0);
const vol = rows.reduce((s, r) => s + Math.abs(r.x.usd), 0);
console.log(`${f}: trades with a >=same-size peer within 30 s: ${rows.length} of ${t.length}; volume $${vol.toFixed(0)}`);
console.log(`worse than such a peer: ${pos.length}; >25 bps worse: ${pos.filter(r => r.gap > 25).length}; >100 bps worse: ${pos.filter(r => r.gap > 100).length}`);
console.log(`sum of observed difference $${pos.reduce((s, r) => s + r.usdGap, 0).toFixed(2)} = ${(pos.reduce((s, r) => s + r.usdGap, 0) / vol * 1e4).toFixed(1)} bps of that volume`);
for (const st of ['regular', 'extended', 'weekend']) { const a = rows.filter(r => state(r.x.ts) === st); if (a.length) console.log(`  ${st}: n ${a.length}, >25bps worse ${a.filter(r => r.gap > 25).length}, $diff ${a.reduce((s, r) => s + r.usdGap, 0).toFixed(2)} on $${a.reduce((s, r) => s + Math.abs(r.x.usd), 0).toFixed(0)}`); }
// does the worse trade pay less gas? (a better route might cost more gas)
console.log('largest differences (trade vs best same-size peer):');
pos.sort((a, b) => b.usdGap - a.usdGap).slice(0, 10).forEach(({ x, best, gap, usdGap }) =>
  console.log(`  ${x.kind} ${x.sym} $${Math.abs(x.usd).toFixed(0)} ${gap.toFixed(0)}bps=$${usdGap.toFixed(2)} | via ${x.ux ? 'UniswapX' : x.to.slice(0, 10) + ' ' + x.sel} ${x.nSwaps} swaps gas $${x.gasUsd.toFixed(3)} | peer $${Math.abs(best.usd).toFixed(0)} via ${best.ux ? 'UniswapX' : best.to.slice(0, 10) + ' ' + best.sel} ${best.nSwaps} swaps gas $${best.gasUsd.toFixed(3)} | ${x.hash.slice(0, 12)} vs ${best.hash.slice(0, 12)}`));
// repeat offenders: which routers are most often worse by >25 bps
const rc = {}; pos.filter(r => r.gap > 25).forEach(r => { const k = r.x.ux ? 'UniswapX' : r.x.to; rc[k] = (rc[k] || 0) + r.usdGap; });
console.log('routers behind >25 bps differences ($):', Object.entries(rc).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([k, v]) => k.slice(0, 10) + ' $' + v.toFixed(2)).join(', '));
