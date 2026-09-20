const RPC='https://rpc.mainnet.chain.robinhood.com';
const XFER='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let id=1, calls=0;
async function rpc(m,p,t=8){
  for(let i=0;i<t;i++){
    try{
      const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
        body:JSON.stringify({jsonrpc:'2.0',id:id++,method:m,params:p})});
      const txt=await r.text();
      if(!r.ok || txt.trim().startsWith('<')){ await sleep(2500*(i+1)); continue; }
      const j=JSON.parse(txt);
      if(j.error){
        if(/Too Many|rate|timed out|limit/i.test(j.error.message)){ await sleep(2000*(i+1)); continue; }
        return {__err:j.error.message};
      }
      calls++; await sleep(300);
      return j.result;
    }catch(e){ await sleep(2000*(i+1)); }
  }
  return {__err:'exhausted'};
}
async function sym(a){const r=await rpc('eth_call',[{to:a,data:'0x95d89b41'},'latest']);
 if(!r||r.__err||r==='0x')return null;try{const len=parseInt(r.slice(66,130),16);
 return Buffer.from(r.slice(130,130+len*2),'hex').toString().replace(/\0/g,'');}catch{return null;}}

const head=parseInt(await rpc('eth_blockNumber',[]),16);
const SPAN=120000, STEP=20000;   // ~3.4h, 6 chunks per token

async function recipients(addr,label){
  const set=new Set();
  for(let to=head; to>head-SPAN; to-=STEP){
    const r=await rpc('eth_getLogs',[{address:addr,fromBlock:'0x'+(to-STEP+1).toString(16),toBlock:'0x'+to.toString(16),topics:[XFER]}]);
    if(r.__err) continue;
    for(const l of r) if(l.topics[2]) set.add('0x'+l.topics[2].slice(26));
  }
  console.log(`  ${label.padEnd(12)} ${set.size}`);
  return set;
}

console.log('EQUITY token recipients (last ~3.4h):');
const EQ={NVDA:'0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
          GOOGL:'0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3',
          AAPL:'0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9',
          SPY :'0xD5f3879160bc7c32ebb4dC785F8a4F505888de68'};
const eq=new Set();
for(const [n,a] of Object.entries(EQ)) for(const x of await recipients(a,n)) eq.add(x);
console.log(`  UNION        ${eq.size}\n`);

// Memecoins observed with sustained USDG volume in the earlier scan, resolved by symbol probe.
// We find them by scanning a small set of high-activity non-equity tokens from Transfer logs.
console.log('Sampling active non-equity tokens from a narrow window...');
const tokenHits={};
for(let to=head; to>head-6000; to-=1500){
  const r=await rpc('eth_getLogs',[{fromBlock:'0x'+(to-1499).toString(16),toBlock:'0x'+to.toString(16),topics:[XFER]}]);
  if(r.__err){ console.log('   window err:',r.__err); continue; }
  for(const l of r) tokenHits[l.address]=(tokenHits[l.address]||0)+1;
}
const eqLower=new Set(Object.values(EQ).map(a=>a.toLowerCase()));
const candidates=Object.entries(tokenHits).filter(([t])=>!eqLower.has(t.toLowerCase()))
  .sort((a,b)=>b[1]-a[1]).slice(0,18).map(([t])=>t);
console.log(`  ${Object.keys(tokenHits).length} tokens active; testing top ${candidates.length} non-equity\n`);

console.log('OVERLAP - addresses that received BOTH an equity token and this token:');
console.log('  TOKEN          recipients  SHARED');
const overlap=new Set(); const rows=[];
for(const m of candidates){
  const set=await recipients(m,'  probing');
  if(!set.size) continue;
  const shared=[...set].filter(a=>eq.has(a));
  const s=await sym(m)||m.slice(0,10);
  rows.push({s,shared:shared.length,n:set.size});
  shared.forEach(a=>overlap.add(a));
}
rows.sort((a,b)=>b.shared-a.shared);
for(const r of rows) console.log(`  ${r.s.padEnd(14)} ${String(r.n).padStart(9)}  ${r.shared}`);

console.log(`\n=== HEADLINE ===`);
console.log(`distinct addresses receiving BOTH an equity token AND a non-equity token: ${overlap.size}`);
let eoa=0,ct=0;
for(const a of [...overlap].slice(0,50)){
  const c=await rpc('eth_getCode',[a,'latest']);
  if(c==='0x') eoa++; else if(!c.__err) ct++;
}
console.log(`of ${Math.min(50,overlap.size)} sampled: ${eoa} EOA (human wallets), ${ct} contracts (routers/pools/bots)`);
console.log(`(rpc calls: ${calls})`);
