const RPC='https://rpc.mainnet.chain.robinhood.com';
const PM='0x8366a39cc670b4001a1121b8f6a443a643e40951';
const INIT='0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';
const SWAP='0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let id=1;
async function rpc(m,p,tries=6){
  for(let i=0;i<tries;i++){
    const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({jsonrpc:'2.0',id:id++,method:m,params:p})});
    const j=await r.json();
    if(j.error){ if(/Too Many|rate|timed out/i.test(j.error.message)){await sleep(1000*(i+1));continue;} return {__err:j.error.message}; }
    await sleep(70); return j.result;
  }
  return {__err:'rate limited'};
}
async function sym(a){const r=await rpc('eth_call',[{to:a,data:'0x95d89b41'},'latest']);
  if(!r||r.__err||r==='0x')return null;try{const len=parseInt(r.slice(66,130),16);
  return Buffer.from(r.slice(130,130+len*2),'hex').toString().replace(/\0/g,'');}catch{return null;}}

const head=parseInt(await rpc('eth_blockNumber',[]),16);
// Sample 4 separate windows spread over ~14h to check volume is SUSTAINED, not a blip
const offsets=[0, 120000, 250000, 400000];
const agg={};
for(const off of offsets){
  const top=head-off;
  for(let to=top; to>top-1000; to-=250){
    const r=await rpc('eth_getLogs',[{address:PM,fromBlock:'0x'+(to-249).toString(16),toBlock:'0x'+to.toString(16),topics:[SWAP]}]);
    if(!r.__err) for(const l of r){ (agg[l.topics[1]] ??= {n:0,windows:new Set()}); agg[l.topics[1]].n++; agg[l.topics[1]].windows.add(off); }
  }
}
console.log(`sampled 4 windows x 1000 blocks across ~11h; ${Object.values(agg).reduce((s,v)=>s+v.n,0)} swaps, ${Object.keys(agg).length} pools\n`);

const cache={};
const nameOf=async a=>cache[a] ??= (a==='0x0000000000000000000000000000000000000000'?'ETH':(await sym(a))||a.slice(0,10));
const STOCK=/^(AAPL|NVDA|TSLA|SPY|MSTR|MSFT|META|AMZN|GOOGL|COIN|QQQ|AMD|INTC|PLTR|CRCL|SGOV|GLD|SLV|SPCX|CRWV|IONQ|RGTI|HOOD)$/i;
const rows=[];
for(const [pid,v] of Object.entries(agg).sort((a,b)=>b[1].n-a[1].n).slice(0,28)){
  const r=await rpc('eth_getLogs',[{address:PM,fromBlock:'0x0',toBlock:'latest',topics:[INIT,pid]}]);
  if(r.__err||!r.length) continue;
  const L=r[0];
  const c0='0x'+L.topics[2].slice(26), c1='0x'+L.topics[3].slice(26);
  const d=L.data.slice(2);
  const fee=parseInt(d.slice(0,64),16);
  const hooks='0x'+d.slice(128+24,192);
  const a=await nameOf(c0), b=await nameOf(c1);
  rows.push({pair:a+'/'+b, n:v.n, w:v.windows.size, fee, hooks,
             stock:STOCK.test(a)||STOCK.test(b), usdg:/USDG/i.test(a+b)});
}
console.log('PAIR                       swaps  windows  fee    hooks');
for(const r of rows) console.log(
  `  ${r.pair.padEnd(24)} ${String(r.n).padStart(5)}    ${r.w}/4   ${String(r.fee).padStart(6)} ${r.hooks==='0x0000000000000000000000000000000000000000'?'none':r.hooks.slice(0,12)+'..'}${r.stock?'  <-STOCK':''}`);

console.log(`\nstock-token pools in top ${rows.length}: ${rows.filter(r=>r.stock).length}`);
console.log(`USDG-quoted pools      : ${rows.filter(r=>r.usdg).length}`);
console.log(`pools with hooks       : ${rows.filter(r=>r.hooks!=='0x0000000000000000000000000000000000000000').length}`);
