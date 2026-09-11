import {test} from 'node:test';
import assert from 'node:assert/strict';
import {feedAlerts} from '../rules.mjs';
import {createMonitor} from '../monitor.mjs';
for(const [name,hard] of [['ETH',10800],['USDG',93600]])for(const delta of [-1,0,1])test(`${name} hard age ${hard+delta}`,()=>{
 const a=feedAlerts(name,[1n,100000000n,0n,BigInt(200000-hard-delta),1n],8,200000);
 assert.equal(a.some(x=>x.msg.includes('HARD_AGE_EXCEEDED')),delta>0);
});
for(const sign of [-1n,1n])for(const delta of [-1n,0n,1n])test(`peg hard band ${sign*(500000n+delta)}`,()=>{
 const a=feedAlerts('USDG',[1n,100000000n+sign*(500000n+delta),0n,1000n,1n],8,1000);
 assert.equal(a.some(x=>x.msg.includes('HARD_DEPEG_EXCEEDED')),delta>0n);
});
function setup({delivery=true,saveFail=false,state}={}) {
 let saved;const seen=[];
 const config={startBlock:1n,blockBatch:2n,confirmations:0n,retries:0,retryDelayMs:0,healthEnabled:false,scope:'test'};
 const chain={feed:async()=>({round:[1n,100000000n,0n,1000n,1n],decimals:8}),head:async()=>10n,blockHash:async()=> 'hash',badDebt:async()=>[0,1].map(logIndex=>({transactionHash:'tx',logIndex,blockNumber:1n,args:{id:1n,debtId:2n,residualDebt:3n}}))};
 return {monitor:createMonitor({chain,config,alert:async(key)=>{seen.push(key);return key.startsWith('BadDebt:')?delivery:true;},clear:()=>{},readHeartbeat:async()=>({updatedAt:1000}),loadState:async()=>state,saveState:async s=>{if(saveFail)throw Error('disk');saved=s;},now:()=>1000}),seen,get saved(){return saved;}};
}
test('different BadDebt logs in same transaction both notify, chunk bounded',async()=>{const f=setup();await f.monitor.tick();assert.ok(f.seen.includes('BadDebt:tx:0'));assert.ok(f.seen.includes('BadDebt:tx:1'));assert.equal(f.saved.nextBlock,'3');assert.ok(f.seen.includes('events:backlog'));});
test('BadDebt failed delivery does not advance durable cursor',async()=>{const f=setup({delivery:false});await f.monitor.tick();assert.equal(f.saved,undefined);assert.ok(f.seen.includes('check:events'));});
test('cursor disk failure alerts after notification',async()=>{const f=setup({saveFail:true});await f.monitor.tick();assert.equal(f.saved,undefined);assert.ok(f.seen.includes('check:events'));});
test('foreign cursor never silently skips history',async()=>{const f=setup({state:{scope:'other',nextBlock:'8',hash:'hash'}});await f.monitor.tick();assert.equal(f.saved,undefined);assert.ok(f.seen.includes('check:events'));assert.ok(!f.seen.some(k=>k.startsWith('BadDebt:')));});
for(const count of [4,5,6])test(`near-position count ${count} vs threshold 5`,async()=>{
 const seen=[];
 const chain={feed:async()=>({round:[1n,100000000n,0n,1000n,1n],decimals:8}),head:async()=>0n,nextPositionId:async()=>BigInt(count+1),lltv:async()=>10n**18n,position:async()=>({value:100n,debt:91n})};
 const monitor=createMonitor({chain,config:{scope:'test',startBlock:1n,confirmations:0n,retries:0,retryDelayMs:0,healthEnabled:true,maxPositions:10,nearCount:5},alert:async key=>{seen.push(key);return true;},clear:()=>{},readHeartbeat:async()=>({updatedAt:1000}),loadState:async()=>undefined,saveState:async()=>{},now:()=>1000});
 await monitor.tick();assert.equal(seen.includes('health:count'),count>=5);
});
