const RPC='https://rpc.mainnet.chain.robinhood.com';
const PM='0x8366a39cc670b4001a1121b8f6a443a643e40951';
const SWAP='0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f';
const INIT='0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';
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
const head=parseInt(await rpc('eth_blockNumber',[]),16);
// Gather swaps and decode the `fee` field actually charged (last uint24 in data)
const feeHist={}; const dynPools={}; let n=0;
for(let to=head; to>head-4000; to-=250){
  const r=await rpc('eth_getLogs',[{address:PM,fromBlock:'0x'+(to-249).toString(16),toBlock:'0x'+to.toString(16),topics:[SWAP]}]);
  if(r.__err) continue;
  for(const l of r){
    n++;
    const d=l.data.slice(2);
    // amount0,amount1,sqrtPriceX96,liquidity,tick,fee  -> fee is word 6 (index 5)
    const fee=parseInt(d.slice(5*64,6*64),16);
    feeHist[fee]=(feeHist[fee]||0)+1;
    (dynPools[l.topics[1]] ??= new Set()).add(fee);
  }
}
console.log(`decoded ${n} swaps\n`);
console.log('ACTUAL FEE CHARGED (from Swap events)  [1e6 = 100%]');
for(const [f,c] of Object.entries(feeHist).sort((a,b)=>b[1]-a[1]).slice(0,12))
  console.log(`  fee=${String(f).padStart(8)}  (${(Number(f)/10000).toFixed(4)}%)  ${c} swaps`);

const varying=Object.entries(dynPools).filter(([,s])=>s.size>1);
console.log(`\npools where the charged fee VARIED between swaps: ${varying.length} of ${Object.keys(dynPools).length}`);
for(const [pid,s] of varying.slice(0,8)){
  const fees=[...s].sort((a,b)=>a-b);
  console.log(`  ${pid.slice(0,14)}..  fees seen: ${fees.map(f=>(f/10000).toFixed(3)+'%').join(', ')}`);
}
