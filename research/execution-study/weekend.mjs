// Weekend 19-20 Sep 2026: last Chainlink print before the weekend, the
// weekend DEX fills (feed frozen), and the first print after the feed resumed.
import { readFileSync } from 'node:fs';
const cl = JSON.parse(readFileSync('sample7d.cl.json'));
const rows = JSON.parse(readFileSync('sample7d.rows.json')).filter(x => (x.kind === 'BUY' || x.kind === 'SELL') && Math.abs(x.usd) >= 1);
const FRI = Date.parse('2026-09-19T00:00:00Z') / 1000, MON = Date.parse('2026-09-21T00:00:00Z') / 1000;
for (const s of ['TSLA', 'NVDA', 'AAPL', 'AMZN', 'GOOGL', 'QQQ']) {
  const h = cl[s] || []; const before = h.filter(x => x.ts < FRI).pop(), after = h.find(x => x.ts >= MON);
  const wk = rows.filter(x => x.sym === s && x.ts >= FRI && x.ts < MON);
  const last = wk.filter(x => x.ts >= Date.parse('2026-09-20T12:00:00Z') / 1000);
  const mid = a => { if (!a.length) return null; const p = a.map(x => x.px).sort((x, y) => x - y); return p[Math.floor(p.length / 2)]; };
  const w = mid(last.length ? last : wk);
  if (!before || !after) { console.log(s, 'feed history incomplete'); continue; }
  const move = (after.price / before.price - 1) * 1e4, dexMove = w ? (w / before.price - 1) * 1e4 : null;
  console.log(`${s.padEnd(5)} Fri last $${before.price.toFixed(2)} (${new Date(before.ts * 1000).toISOString().slice(5, 16)}) | weekend DEX median fill ${w ? '$' + w.toFixed(2) : '-'} (n=${(last.length ? last : wk).length}) | first print after $${after.price.toFixed(2)} (${new Date(after.ts * 1000).toISOString().slice(5, 16)}) | feed move ${move.toFixed(0)} bps, DEX weekend move ${dexMove?.toFixed(0) ?? '-'} bps`);
}
