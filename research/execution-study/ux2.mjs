import { batch, TRANSFER } from './rpc.mjs';
import { readFileSync } from 'node:fs';
const all = JSON.parse(readFileSync('uniswapx_txs.json'));
const txs = [...new Set(all)].filter((_, i) => i % 3 === 0).slice(0, 120);
const meta = JSON.parse(readFileSync('tokens.json'));
const STOCKS = new Set(['0x322f0929c4625ed5bad873c95208d54e1c003b2d','0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec','0xaf3d76f1834a1d425780943c99ea8a608f8a93f9','0x12f190a9f9d7d37a250758b26824b97ce941bf54','0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3','0xd5f3879160bc7c32ebb4dc785f8a4f505888de68']);
const tokCount = {}; let withStock = 0, n = 0; const fillerTo = {};
for (let i = 0; i < txs.length; i += 20) {
  const rc = await batch(txs.slice(i, i + 20).map(h => ['eth_getTransactionReceipt', [h]]));
  for (const r of rc) {
    if (!r || r.__err) continue; n++;
    fillerTo[r.to] = (fillerTo[r.to] || 0) + 1;
    const toks = new Set(r.logs.filter(l => l.topics[0] === TRANSFER && l.topics.length === 3).map(l => l.address.toLowerCase()));
    if ([...toks].some(t => STOCKS.has(t))) withStock++;
    for (const t of toks) { const s = meta[t]?.sym || t.slice(0, 10); tokCount[s] = (tokCount[s] || 0) + 1; }
  }
}
console.log('fills inspected', n, 'touching the 6 Stock Tokens', withStock);
console.log('tokens', Object.entries(tokCount).sort((a, b) => b[1] - a[1]).slice(0, 15));
console.log('tx.to', Object.entries(fillerTo).sort((a, b) => b[1] - a[1]).slice(0, 5));
