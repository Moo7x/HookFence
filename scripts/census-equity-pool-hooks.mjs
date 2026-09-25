const RPC='https://rpc.mainnet.chain.robinhood.com';
const PM='0x8366a39cc670b4001a1121b8f6a443a643e40951';
const INIT='0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let id=1;
async function rpc(m,p,t=6){for(let i=0;i<t;i++){
  try{const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:id++,method:m,params:p})});
  const txt=await r.text(); if(!r.ok||txt.trim().startsWith('<')){await sleep(1200*(i+1));continue;}
  const j=JSON.parse(txt);
  if(j.error){ if(/Too Many|rate|timed out|limit/i.test(j.error.message)){await sleep(1200*(i+1));continue;} return {__err:j.error.message};}
  await sleep(120); return j.result;}catch(e){await sleep(1200*(i+1));}}
  return {__err:'exhausted'};}
const pad=a=>'0x'+a.toLowerCase().replace('0x','').padStart(64,'0');

const STOCKS={NVDA:'0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
              GOOGL:'0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3',
              QQQ:'0xD5f3879160bc7c32ebb4dC785F8a4F505888de68',
              AAPL:'0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9'};
const ZERO='0x0000000000000000000000000000000000000000';
const head=parseInt(await rpc('eth_blockNumber',[]),16);

const hookCount={}; let totalPools=0, hooked=0;
for(const [sym,addr] of Object.entries(STOCKS)){
  let pools=0, wh=0;
  for(const slot of [2,3]){
    const topics=[INIT,null,null,null]; topics[slot]=pad(addr);
    for(let to=head; to>0; to-=1500000){
      const from=Math.max(0,to-1500000);
      const r=await rpc('eth_getLogs',[{address:PM,fromBlock:'0x'+from.toString(16),toBlock:'0x'+to.toString(16),topics:topics.slice(0,slot+1)}]);
      if(r.__err){ continue; }
      for(const l of r){
        pools++;
        const d=l.data.slice(2);
        const hook='0x'+d.slice(128+24,192);
        if(hook!==ZERO){ wh++; hookCount[hook]=(hookCount[hook]||0)+1; }
      }
      if(from===0) break;
    }
  }
  totalPools+=pools; hooked+=wh;
  console.log(`  ${sym.padEnd(6)} pools=${String(pools).padStart(5)}  with hooks=${wh}`);
}
console.log(`\nTOTAL stock-token pools sampled: ${totalPools}, with hooks: ${hooked}`);
console.log(`distinct hook contracts on stock-token pools: ${Object.keys(hookCount).length}\n`);

console.log('TOP HOOKS on tokenized-equity pools (address, #pools, codesize):');
for(const [h,n] of Object.entries(hookCount).sort((a,b)=>b[1]-a[1]).slice(0,12)){
  const code=await rpc('eth_getCode',[h,'latest']);
  const size=(typeof code==='string')?(code.length-2)/2:0;
  // decode hook permission flags from the address
  const bits=BigInt(h) & 0x3FFFn;
  const names=[];
  const F={8192:'beforeInit',4096:'afterInit',2048:'beforeAddLiq',1024:'afterAddLiq',
           512:'beforeRemoveLiq',256:'afterRemoveLiq',128:'BEFORE_SWAP',64:'AFTER_SWAP',
           32:'beforeDonate',16:'afterDonate',8:'BEFORE_SWAP_DELTA',4:'AFTER_SWAP_DELTA',
           2:'addLiqDelta',1:'removeLiqDelta'};
  for(const [bit,nm] of Object.entries(F)) if(bits & BigInt(bit)) names.push(nm);
  console.log(`  ${h}  pools=${String(n).padStart(4)}  code=${size}B`);
  console.log(`      permissions: ${names.join(', ')||'none'}`);
}
