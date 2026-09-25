import { rpc } from './rpc.mjs';
import { readFileSync } from 'node:fs';
const { keccak256, toHex } = await import(new URL('../../tools/node_modules/viem/_esm/index.js', import.meta.url).href);
const T = keccak256(toHex('ReserveInitialized(address,address,address,address,address)'));
const meta = JSON.parse(readFileSync('tokens.json'));
const head = parseInt(await rpc('eth_blockNumber', []), 16);
const logs = []; for (let to = head; to > 0; to -= 3_000_000) logs.push(...await rpc('eth_getLogs', [{ fromBlock: '0x' + Math.max(0, to - 2_999_999).toString(16), toBlock: '0x' + to.toString(16), topics: [T] }]));
const byDep = {};
for (const l of logs) (byDep[l.address] ??= []).push({ asset: '0x' + l.topics[1].slice(26), aToken: '0x' + l.topics[2].slice(26), varDebt: '0x' + l.data.slice(2 + 64 + 24, 2 + 128) });
const ts = async a => { try { return BigInt(await rpc('eth_call', [{ to: a, data: '0x18160ddd' }, 'latest'])); } catch { return 0n; } };
const sym = async a => { if (meta[a]) return meta[a]; try { const s = await rpc('eth_call', [{ to: a, data: '0x95d89b41' }, 'latest']); const b = Buffer.from(s.slice(2), 'hex'); const d = parseInt(await rpc('eth_call', [{ to: a, data: '0x313ce567' }, 'latest']), 16); return meta[a] = { sym: b.length === 32 ? b.toString().replace(/\0/g, '') : b.slice(64, 64 + Number(BigInt('0x' + s.slice(66, 130)))).toString(), dec: d }; } catch { return { sym: a.slice(0, 8), dec: 18 }; } };
for (const [dep, rs] of Object.entries(byDep)) {
  const parts = [];
  for (const r of rs) { const m = await sym(r.asset); const sup = Number(await ts(r.aToken)) / 10 ** m.dec, bor = Number(await ts(r.varDebt)) / 10 ** m.dec;
    if (sup > 0.0001 || bor > 0) parts.push(`${m.sym}: dep ${sup.toFixed(3)} bor ${bor.toFixed(3)}`); }
  console.log(dep.slice(0, 10), rs.length, 'reserves |', parts.join(' | ') || 'empty');
}
