import { rpc } from './rpc.mjs';
const { keccak256, toHex } = await import(new URL('../../tools/node_modules/viem/_esm/index.js', import.meta.url).href);
const FILL = keccak256(toHex('Fill(bytes32,address,address,uint256)'));
const head = parseInt(await rpc('eth_blockNumber', []), 16);
const reactors = {}; let total = 0; const txs = [];
// 7 days back in 200k-block steps (~5.6h each)
for (let to = head; to > head - 7 * 855000; to -= 200000) {
  const r = await rpc('eth_getLogs', [{ fromBlock: '0x' + (to - 199999).toString(16), toBlock: '0x' + to.toString(16), topics: [FILL] }]);
  for (const l of r) { reactors[l.address] = (reactors[l.address] || 0) + 1; total++; if (txs.length < 400) txs.push(l.transactionHash); }
}
console.log('Fill topic', FILL, 'total fills in 7d', total, reactors);
import { writeFileSync } from 'node:fs'; writeFileSync('uniswapx_txs.json', JSON.stringify(txs));
