// UniswapX fills in the same 14 windows as sample7d.json, merged in as extra transactions.
import { rpc, batch } from './rpc.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
const FILL = '0x78ad7ec0e9f89e74012afa58738b6b661c024cb0fd185ee2f616c0a28924bd66';
const S = JSON.parse(readFileSync('sample7d.json'));
const have = new Set(S.txs.map(t => t.hash));
const STOCKS = new Set(Object.values(S.tokens).map(a => a.toLowerCase()));
const TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const hashes = new Map();
for (const to of Object.keys(S.stamps).map(Number)) {
  const logs = await rpc('eth_getLogs', [{ fromBlock: '0x' + (to - 2000).toString(16), toBlock: '0x' + to.toString(16), topics: [FILL] }]);
  for (const l of logs) if (!have.has(l.transactionHash)) hashes.set(l.transactionHash, parseInt(l.blockNumber, 16));
}
console.log('fills not already in sample', hashes.size);
const list = [...hashes.keys()]; let added = 0, stockFills = 0;
for (let i = 0; i < list.length; i += 30) {
  const chunk = list.slice(i, i + 30);
  const rc = await batch(chunk.map(h => ['eth_getTransactionReceipt', [h]]));
  const tx = await batch(chunk.map(h => ['eth_getTransactionByHash', [h]]));
  chunk.forEach((h, k) => {
    const r = rc[k], t = tx[k]; if (!r || !t || r.__err || t.__err) return;
    const toks = r.logs.filter(l => l.topics[0] === TRANSFER).map(l => l.address.toLowerCase());
    const hit = Object.entries(S.tokens).filter(([, a]) => toks.includes(a.toLowerCase())).map(([s]) => s);
    if (!hit.length) return;
    stockFills++;
    S.txs.push({ hash: h, block: hashes.get(h), tokens: hit, from: t.from, to: t.to, value: t.value, input4: t.input.slice(0, 10), status: r.status,
      gasUsed: r.gasUsed, effectiveGasPrice: r.effectiveGasPrice, logs: r.logs.map(l => ({ address: l.address, topics: l.topics, data: l.data })) });
    added++;
  });
}
writeFileSync('sample7d.json', JSON.stringify(S));
console.log('stock-token UniswapX fills added', added);
