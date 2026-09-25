// Stage 1: sample real Stock Token trades on Robinhood Chain mainnet.
// For windows spread over the last 7 days, find every transaction that moved a
// Stock Token into or out of the v4 PoolManager, then fetch the transaction and
// receipt. Saves raw data to sample.json for analysis.
import { rpc, batch, pad, PM, TRANSFER } from './rpc.mjs';
import { writeFileSync, readFileSync, existsSync } from 'node:fs';

const TOKENS = {
  TSLA: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d',
  NVDA: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
  AAPL: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9',
  AMZN: '0x12f190a9F9d7D37a250758b26824B97CE941bF54',
  GOOGL: '0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3',
  QQQ: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68',
};
const WINDOWS = Number(process.env.WINDOWS || 14);
const SPAN = Number(process.env.SPAN || 6000); // ~10 minutes per window
const DAYS = Number(process.env.DAYS || 7);

const CK = (process.env.OUT || 'sample.json') + '.ck.json';
const ck = existsSync(CK) ? JSON.parse(readFileSync(CK)) : null;
const head = ck ? ck.head : parseInt(await rpc('eth_blockNumber', []), 16);
const back = Math.round(DAYS * 86400 * 9.89);
const txs = new Map(); // hash -> {block, tokens:Set}
if (ck) for (const [h, v] of ck.txs) txs.set(h, { block: v.block, tokens: new Set(v.tokens) });
const ENDS = process.env.ENDS ? process.env.ENDS.split(',').map(Number) : null;
const NW = ENDS ? ENDS.length : WINDOWS;
for (let w = 0; w < NW && !ck; w++) {
  const to = ENDS ? ENDS[w] : head - Math.round((back * w) / WINDOWS);
  const from = to - SPAN;
  for (const [sym, addr] of Object.entries(TOKENS)) {
    for (const topics of [[TRANSFER, pad(PM)], [TRANSFER, null, pad(PM)]]) {
      const logs = await rpc('eth_getLogs', [{ address: addr, fromBlock: '0x' + from.toString(16), toBlock: '0x' + to.toString(16), topics }]);
      for (const l of logs) {
        const t = txs.get(l.transactionHash) || { block: parseInt(l.blockNumber, 16), tokens: new Set() };
        t.tokens.add(sym);
        txs.set(l.transactionHash, t);
      }
    }
  }
  process.stderr.write(`window ${w} [${from}-${to}] txs so far ${txs.size}\n`);
}

if (!ck) writeFileSync(CK, JSON.stringify({ head, txs: [...txs].map(([h, v]) => [h, { block: v.block, tokens: [...v.tokens] }]), done: [] }));
const PART = CK + '.part.json';
const out = existsSync(PART) ? JSON.parse(readFileSync(PART)) : [];
const doneSet = new Set(out.map(o => o.hash));
const hashes = [...txs.keys()].filter(h => !doneSet.has(h));
for (let i = 0; i < hashes.length; i += 40) {
  if (i % 400 === 0) writeFileSync(PART, JSON.stringify(out));
  const chunk = hashes.slice(i, i + 40);
  const [txr, rcr] = [await batch(chunk.map(h => ['eth_getTransactionByHash', [h]])), await batch(chunk.map(h => ['eth_getTransactionReceipt', [h]]))];
  chunk.forEach((h, k) => {
    const tx = txr[k], rc = rcr[k];
    if (!tx || !rc || tx.__err || rc.__err) return;
    out.push({ hash: h, block: txs.get(h).block, tokens: [...txs.get(h).tokens], from: tx.from, to: tx.to, value: tx.value,
      input4: tx.input.slice(0, 10), status: rc.status, gasUsed: rc.gasUsed, effectiveGasPrice: rc.effectiveGasPrice,
      logs: rc.logs.map(l => ({ address: l.address, topics: l.topics, data: l.data })) });
  });
  process.stderr.write(`receipts ${out.length}/${hashes.length}\n`);
}
// block timestamps per window (one per window is enough; 10 blocks/s)
const stamps = {};
for (let w = 0; w < NW; w++) {
  const to = ENDS ? ENDS[w] : head - Math.round((back * w) / WINDOWS);
  const b = await rpc('eth_getBlockByNumber', ['0x' + to.toString(16), false]);
  stamps[to] = parseInt(b.timestamp, 16);
}
writeFileSync(process.env.OUT || 'sample.json', JSON.stringify({ head, stamps, tokens: TOKENS, txs: out }));
console.log('saved', out.length, 'transactions');
