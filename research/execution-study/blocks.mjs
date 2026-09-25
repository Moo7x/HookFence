import { rpc } from './rpc.mjs';
const ts = async b => parseInt((await rpc('eth_getBlockByNumber', ['0x' + b.toString(16), false])).timestamp, 16);
const head = parseInt(await rpc('eth_blockNumber', []), 16); const hts = await ts(head);
const out = [];
for (const iso of process.argv.slice(2)) {
  const target = Date.parse(iso) / 1000;
  let b = head - Math.round((hts - target) * 9.89);
  for (let i = 0; i < 6; i++) { const t = await ts(b); const d = target - t; if (Math.abs(d) < 3) break; b += Math.round(d * 9.89); }
  out.push(b);
}
console.log(out.join(','));
