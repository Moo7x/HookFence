export const RPC = 'https://rpc.mainnet.chain.robinhood.com';
let id = 1;
const sleep = ms => new Promise(r => setTimeout(r, ms));
export async function rpc(method, params, tries = 12) {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: id++, method, params }) });
      const txt = await r.text();
      if (r.status === 429 || /too many/i.test(txt) || txt.trim().startsWith('<')) { last = new Error('http ' + r.status + ' ' + txt.slice(0, 80)); await sleep(600 * 2 ** Math.min(i, 5)); continue; }
      const j = JSON.parse(txt);
      if (j.error) { if (/rate|timed out|timeout/i.test(j.error.message)) { await sleep(800 * (i + 1)); continue; } throw new Error(method + ': ' + j.error.message); }
      return j.result;
    } catch (e) { last = e; if (/^eth_\w+: /.test(e.message)) throw e; await sleep(1000 * (i + 1)); }
  }
  throw new Error('exhausted ' + method + ' ' + (last?.message || ''));
}
export async function batch(calls) {
  for (let i = 0; i < 25; i++) {
    const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(calls.map(([m, p]) => ({ jsonrpc: '2.0', id: id++, method: m, params: p }))) });
    const txt = await r.text();
    if (r.status === 429 || /too many/i.test(txt) || txt.trim().startsWith('<')) { await sleep(1000 * 2 ** Math.min(i, 4)); continue; }
    let j; try { j = JSON.parse(txt); } catch { await sleep(2000); continue; }
    if (!Array.isArray(j)) { await sleep(800 * (i + 1)); continue; }
    j.sort((a, b) => a.id - b.id);
    if (j.some(x => x.error && /rate|too many/i.test(x.error.message))) { await sleep(800 * (i + 1)); continue; }
    return j.map(x => x.error ? { __err: x.error.message } : x.result);
  }
  throw new Error('batch exhausted');
}
export const pad = a => '0x' + a.toLowerCase().replace('0x', '').padStart(64, '0');
export const PM = '0x8366a39cc670b4001a1121b8f6a443a643e40951';
export const TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
export const SWAP = '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f';
