import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createMonitor,retryRead} from '../monitor.mjs';
function fixture(overrides={},options={}) {
  const alerts=[]; let saved;
  const config={startBlock:1n,blockBatch:10n,confirmations:0n,retries:1,retryDelayMs:0,healthEnabled:true,maxPositions:10,nearCount:2,scope:'test'};
  const chain={feed:async()=>({round:[1n,100000000n,0n,1000n,1n],decimals:8}),head:async()=>2n,blockHash:async n=>`hash${n}`,badDebt:async()=>[],nextPositionId:async()=>3n,position:async()=>({value:100n,debt:91n}),lltv:async()=>10n**18n,...overrides};
  const monitor=createMonitor({chain,config,alert:async(key,level,msg)=>{alerts.push({key,level,msg});return true;},clear:()=>{},readHeartbeat:async()=>({updatedAt:1000}),loadState:async()=>saved,saveState:async s=>{saved=s;},now:()=>1000,...options});
  return {monitor,alerts,get saved(){return saved;},config};
}
test('RPC retries are bounded and recover',async()=>{let n=0;assert.equal(await retryRead(async()=>{if(++n<3)throw Error('private');return 7;},{retries:2,retryDelayMs:0}),7);assert.equal(n,3);});
test('RPC retry exhaustion uses sanitized error',async()=>{await assert.rejects(retryRead(async()=>{throw Error('private');},{retries:1,retryDelayMs:0}),/^Error: read failed$/);});
test('feed failure does not prevent heartbeat, other feed, events or health',async()=>{
 const f=fixture({feed:async name=>{if(name==='ETH')throw Error('secret');return {round:[1n,100300000n,0n,1000n,1n],decimals:8};},badDebt:async()=>[{transactionHash:'0xabc',logIndex:0,args:{id:1n,debtId:2n,residualDebt:3n},blockNumber:2n}]});
 await f.monitor.tick(); assert.ok(f.alerts.some(a=>a.key==='check:ETH'));assert.ok(f.alerts.some(a=>a.key==='USDG:peg'));assert.ok(f.alerts.some(a=>a.key.startsWith('BadDebt:')));assert.ok(f.alerts.some(a=>a.key==='health:count'));assert.equal(f.saved.nextBlock,'3');assert.ok(!JSON.stringify(f.alerts).includes('secret'));
});
test('event cursor resumes after restart without skipping blocks',async()=>{const ranges=[];const f=fixture({badDebt:async(a,b)=>{ranges.push([a,b]);return [];}});await f.monitor.tick();await f.monitor.tick();assert.deepEqual(ranges,[[1n,2n]]);});
test('failed event query does not advance cursor',async()=>{const f=fixture({badDebt:async()=>{throw Error('RPC');}});await f.monitor.tick();assert.equal(f.saved,undefined);assert.ok(f.alerts.some(a=>a.key==='check:events'));});
test('reorg stops cursor advancement and alerts',async()=>{let hash='a';const f=fixture({blockHash:async()=>hash});await f.monitor.tick();hash='b';await f.monitor.tick();assert.ok(f.alerts.some(a=>a.key==='check:events'));assert.equal(f.saved.hash,'a');});
test('health count below threshold does not warn',async()=>{const f=fixture({position:async()=>({value:100n,debt:90n})});await f.monitor.tick();assert.ok(!f.alerts.some(a=>a.key==='health:count'));});
test('partial health scan never reports healthy count',async()=>{const f=fixture({position:async()=>{throw Error('private');}});await f.monitor.tick();assert.ok(f.alerts.some(a=>a.key==='check:health'));assert.ok(!f.alerts.some(a=>a.key==='health:count'));});

test('slow events do not block later feed and heartbeat polls or overlap event scans',async()=>{
 let release;const blocked=new Promise(resolve=>{release=resolve;});let events=0,feeds=0,beats=0;
 const f=fixture({feed:async()=>{feeds++;return {round:[1n,100000000n,0n,1000n,1n],decimals:8};},badDebt:async()=>{events++;await blocked;return [];}},{readHeartbeat:async()=>{beats++;return {updatedAt:1000};}});
 let firstReturned=false;
 const first=f.monitor.tick({wait:false}).then(()=>{firstReturned=true;});
 try {
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(firstReturned,true,'daemon tick must return while events are blocked');
  await f.monitor.tick({wait:false});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(feeds,4);assert.equal(beats,2);assert.equal(events,1);
  assert.ok(f.alerts.some(a=>a.key==='slow:events'));
 } finally {release();await first;if(f.monitor.drain)await f.monitor.drain();}
});

test('abort stops remaining health reads and event delivery without advancing cursor',async()=>{
 const controller=new AbortController();let positions=0,deliveries=0;
 const logs=Array.from({length:3},(_,i)=>({transactionHash:`tx${i}`,logIndex:i,args:{id:1n,debtId:2n,residualDebt:3n},blockNumber:2n}));
 const f=fixture({badDebt:async()=>logs,position:async()=>{positions++;return {value:100n,debt:91n};}},{signal:controller.signal,alert:async key=>{if(key.startsWith('BadDebt:')){deliveries++;controller.abort();}return true;}});
 await f.monitor.tick();assert.equal(deliveries,1);assert.equal(f.saved,undefined);
 await f.monitor.tick();assert.equal(deliveries,1);assert.ok(positions<=2);
});
test('abort after an in-flight position read stops the rest of a large health batch',async()=>{
 const controller=new AbortController();let positions=0;
 const f=fixture({nextPositionId:async()=>10n,position:async()=>{positions++;controller.abort();return {value:100n,debt:91n};}},{signal:controller.signal});
 await f.monitor.tick();assert.equal(positions,1);assert.ok(!f.alerts.some(a=>a.key==='health:count'));
});

test('a failed later log chunk leaves the entire event cursor unchanged',async()=>{
 const {createChain}=await import('../adapter.mjs');const calls=[];
 const adapted=createChain({getLogs:async r=>{calls.push([r.fromBlock,r.toBlock]);if(r.fromBlock>1n)throw Object.assign(Error('RPC retry budget exhausted'),{rpcExhausted:true});return []; }},{vault:'0x'+'1'.repeat(40),logBlockRange:1n});
 const f=fixture({badDebt:adapted.badDebt});
 await f.monitor.tick();assert.equal(f.saved,undefined);assert.ok(f.alerts.some(a=>a.key==='check:events'));
 assert.deepEqual(calls,[[1n,1n],[2n,2n]]);
});
