import { rpc } from './rpc.mjs';
import { writeFileSync, readFileSync } from 'node:fs';
const { keccak256, toHex } = await import(new URL('../../tools/node_modules/viem/_esm/index.js', import.meta.url).href);
const M = '0x9d53d5e3bd5e8d4cbfa6db1ca238aea02e651010';
const CREATE = keccak256(toHex('CreateMarket(bytes32,(address,address,address,address,uint256))'));
const LIQ = keccak256(toHex('Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)'));
const meta = JSON.parse(readFileSync('tokens.json'));
const STOCK = { '0x322f0929c4625ed5bad873c95208d54e1c003b2d': 'TSLA', '0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec': 'NVDA', '0xaf3d76f1834a1d425780943c99ea8a608f8a93f9': 'AAPL', '0x12f190a9f9d7d37a250758b26824b97ce941bf54': 'AMZN', '0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3': 'GOOGL', '0xd5f3879160bc7c32ebb4dc785f8a4f505888de68': 'QQQ' };
const head = parseInt(await rpc('eth_blockNumber', []), 16);
const logsAll = async (topics) => { const out = []; for (let to = head; to > 0; to -= 3_000_000) out.push(...await rpc('eth_getLogs', [{ address: M, fromBlock: '0x' + Math.max(0, to - 2_999_999).toString(16), toBlock: '0x' + to.toString(16), topics }])); return out; };
const creates = await logsAll([CREATE]);
const markets = {};
for (const l of creates) { const d = l.data.slice(2); const w = i => '0x' + d.slice(64 * i + 24, 64 * i + 64);
  const loan = w(0), coll = w(1); if (!STOCK[coll]) continue;
  markets[l.topics[1]] = { coll: STOCK[coll], loan: meta[loan]?.sym || loan, loanAddr: loan, oracle: w(2), lltv: Number(BigInt('0x' + d.slice(256, 320))) / 1e18, block: parseInt(l.blockNumber, 16) }; }
// market(id) -> totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee (uint128 each)
const sel = keccak256(toHex('market(bytes32)')).slice(0, 10);
const decs = {};
for (const [id, m] of Object.entries(markets)) {
  const r = await rpc('eth_call', [{ to: M, data: sel + id.slice(2) }, 'latest']);
  const dec = meta[m.loanAddr]?.dec ?? (decs[m.loanAddr] ??= parseInt(await rpc('eth_call', [{ to: m.loanAddr, data: '0x313ce567' }, 'latest']), 16));
  m.supply = Number(BigInt('0x' + r.slice(2, 66))) / 10 ** dec; m.borrow = Number(BigInt('0x' + r.slice(130, 194))) / 10 ** dec;
  if (!meta[m.loanAddr]) { try { const s = await rpc('eth_call', [{ to: m.loanAddr, data: '0x95d89b41' }, 'latest']); const b = Buffer.from(s.slice(2), 'hex'); m.loan = b.slice(64, 64 + Number(BigInt('0x' + s.slice(66, 130)))).toString(); } catch {} }
}
const liqs = await logsAll([LIQ]);
const L = liqs.filter(l => markets[l.topics[1]]).map(l => { const d = l.data.slice(2); const n = i => BigInt('0x' + d.slice(64 * i, 64 * i + 64));
  return { id: l.topics[1], block: parseInt(l.blockNumber, 16), tx: l.transactionHash, borrower: '0x' + l.topics[3].slice(26), repaid: n(0), seized: n(2), badDebt: n(3) }; });
writeFileSync('morpho.json', JSON.stringify({ markets, liqs: L.map(x => ({ ...x, repaid: x.repaid.toString(), seized: x.seized.toString(), badDebt: x.badDebt.toString() })) }));
const rows = Object.entries(markets).sort((a, b) => b[1].borrow - a[1].borrow);
console.log('stock-collateral Morpho markets', rows.length, 'total liquidations on them', L.length, '(all Morpho liquidations', liqs.length + ')');
for (const [id, m] of rows.slice(0, 20)) console.log(`${m.coll.padEnd(5)} / ${String(m.loan).padEnd(8)} lltv ${(m.lltv * 100).toFixed(1)}% supply ${m.supply.toFixed(0).padStart(9)} borrow ${m.borrow.toFixed(0).padStart(9)} oracle ${m.oracle.slice(0, 10)} liqs ${L.filter(x => x.id === id).length} badDebt ${L.filter(x => x.id === id && x.badDebt > 0n).length}  ${id.slice(0, 10)}`);
