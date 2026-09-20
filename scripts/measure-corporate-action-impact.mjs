const RPC='https://rpc.mainnet.chain.robinhood.com';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let id=1;
async function rpc(m,p,t=6){for(let i=0;i<t;i++){
  try{const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:id++,method:m,params:p})});
  const txt=await r.text(); if(!r.ok||txt.trim().startsWith('<')){await sleep(1200*(i+1));continue;}
  const j=JSON.parse(txt);
  if(j.error){ if(/Too Many|rate|timed out/i.test(j.error.message)){await sleep(1200*(i+1));continue;} return {__err:j.error.message};}
  await sleep(120); return j.result;}catch(e){await sleep(1200*(i+1));}}
  return {__err:'exhausted'};}

const hex=n=>'0x'+n.toString(16);
function decodeRound(r){
  const d=r.slice(2);
  const u=i=>BigInt('0x'+d.slice(i*64,(i+1)*64));
  const toInt=v=> v >= (1n<<255n) ? v-(1n<<256n) : v;
  return {roundId:u(0), answer:toInt(u(1)), updatedAt:Number(u(3))};
}
// getRoundData(uint80) = 0x9a6fc8f5
const GRD='0x9a6fc8f5';
async function roundAt(feed, rid){
  const data=GRD+rid.toString(16).padStart(64,'0');
  const r=await rpc('eth_call',[{to:feed,data},'latest']);
  if(r.__err||!r||r==='0x') return null;
  try{ return decodeRound(r); }catch{ return null; }
}

// Events to test: (symbol, feed, effectiveAt unix, multiplier % change)
const TESTS=[
  {sym:'SPY',  feed:'0x319724394D3A0e3669269846abE664Cd621f9f6A', eff:Date.parse('2026-09-18T00:10:00Z')/1000, pct:0.1718},
  {sym:'NVDA', feed:'0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15', eff:Date.parse('2026-09-10T00:00:00Z')/1000, pct:0.0775},
  {sym:'MSFT', feed:'0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E', eff:Date.parse('2026-09-11T15:10:00Z')/1000, pct:0.0413},
];

for(const t of TESTS){
  console.log(`\n=== ${t.sym}: multiplier +${t.pct}% effective ${new Date(t.eff*1000).toISOString()} ===`);
  const latest=await rpc('eth_call',[{to:t.feed,data:'0xfeaf968c'},'latest']);
  if(latest.__err){ console.log('  latestRoundData ERR',latest.__err); continue; }
  const L=decodeRound(latest);
  console.log(`  latest round ${L.roundId}  $${(Number(L.answer)/1e8).toFixed(4)}  ${new Date(L.updatedAt*1000).toISOString()}`);

  // walk back to find rounds bracketing t.eff
  let rid=L.roundId, before=null, after=null, steps=0;
  while(steps<400){
    const r=await roundAt(t.feed, rid);
    if(!r || r.updatedAt===0){ rid=rid-1n; steps++; continue; }
    if(r.updatedAt >= t.eff){ after=r; } else { before=r; break; }
    rid=rid-1n; steps++;
  }
  if(!before||!after){ console.log(`  could not bracket (steps=${steps}, before=${!!before}, after=${!!after})`); continue; }
  const b=Number(before.answer)/1e8, a=Number(after.answer)/1e8;
  const move=((a-b)/b*100);
  console.log(`  last round BEFORE : $${b.toFixed(4)}  ${new Date(before.updatedAt*1000).toISOString()}`);
  console.log(`  first round AFTER : $${a.toFixed(4)}  ${new Date(after.updatedAt*1000).toISOString()}`);
  console.log(`  feed move across the corporate action: ${move>=0?'+':''}${move.toFixed(4)}%`);
  console.log(`  multiplier move                      : +${t.pct}%`);
  console.log(`  => ${Math.abs(move-t.pct)<0.05 ? 'MATCHES multiplier (feed includes it, pool WOULD be mispriced)' : 'does NOT match multiplier alone (dominated by share-price noise)'}`);
}
