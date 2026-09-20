const RPC='https://rpc.mainnet.chain.robinhood.com';
const TOPIC='0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055';
let id=1;
async function rpc(m,p){const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
  body:JSON.stringify({jsonrpc:'2.0',id:id++,method:m,params:p})});const j=await r.json();
  if(j.error) throw new Error(j.error.message); return j.result;}
async function sym(a){try{const r=await rpc('eth_call',[{to:a,data:'0x95d89b41'},'latest']);
  const len=parseInt(r.slice(66,130),16);return Buffer.from(r.slice(130,130+len*2),'hex').toString();}catch{return '?';}}

const head=parseInt(await rpc('eth_blockNumber',[]),16);
const CHUNK=5_000_000;
let all=[];
for(let to=head; to>0; to-=CHUNK){
  const from=Math.max(0,to-CHUNK);
  try{
    const logs=await rpc('eth_getLogs',[{fromBlock:'0x'+from.toString(16),toBlock:'0x'+to.toString(16),topics:[TOPIC]}]);
    all.push(...logs);
    process.stderr.write(`  blocks ${from}-${to}: ${logs.length}\n`);
  }catch(e){ process.stderr.write(`  blocks ${from}-${to}: ERR ${e.message}\n`); }
  if(from===0) break;
}
console.log('TOTAL UIMultiplierUpdated events:', all.length);

const rows=[];
for(const l of all){
  const d=l.data.slice(2);
  const oldM=BigInt('0x'+d.slice(0,64)), newM=BigInt('0x'+d.slice(64,128)), eff=Number(BigInt('0x'+d.slice(128,192)));
  rows.push({addr:l.address, blk:parseInt(l.blockNumber,16), oldM, newM, eff,
             pct: Number(newM*10000000n/oldM)/100000 - 100});
}
rows.sort((a,b)=>a.eff-b.eff);
console.log('\ndate range:', new Date(rows[0].eff*1000).toISOString().slice(0,10), '->', new Date(rows.at(-1).eff*1000).toISOString().slice(0,10));

const cache={};
console.log('\nSYMBOL   CHANGE%    effectiveAt (UTC)        old -> new');
for(const r of rows){
  cache[r.addr] ??= await sym(r.addr);
  console.log(`${(cache[r.addr]||'?').padEnd(8)} ${r.pct.toFixed(4).padStart(8)}%  ${new Date(r.eff*1000).toISOString().slice(0,16)}  ${r.oldM} -> ${r.newM}`);
}
const days=(rows.at(-1).eff-rows[0].eff)/86400;
console.log(`\ndistinct tokens paying: ${new Set(rows.map(r=>r.addr)).size}`);
console.log(`window: ${days.toFixed(1)} days -> ${(rows.length/days*30).toFixed(1)} events/month at this rate`);
console.log(`mean payment: ${(rows.reduce((s,r)=>s+r.pct,0)/rows.length).toFixed(4)}%`);
