import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRpcRequest,RH_RPC_URLS} from '../rpc.mjs';

test('persistent 403/429 gets browser UA, exponential cooldown and all RH endpoints',async()=>{
  let time=0;const requests=[],delays=[];
  const rpc=createRpcRequest({rpcUrl:RH_RPC_URLS[0],chainId:4663},{
    now:()=>time,sleep:async ms=>{delays.push(ms);time+=ms;},
    fetch:async(url,options)=>{requests.push({url,options});return requests.length<8
      ?{ok:false,status:requests.length===1?429:403}
      :{ok:true,json:async()=>({result:'0x1237'})};},
  });
  assert.equal(await rpc.request({method:'eth_chainId',params:[]}),'0x1237');
  assert.deepEqual(new Set(requests.map(r=>r.url)),new Set(RH_RPC_URLS));
  assert.ok(requests.every(r=>r.options.headers['User-Agent'].includes('Mozilla/5.0')));
  assert.ok(time>=120000 && time<=180000);assert.ok(Math.max(...delays)>=45000);
});

test('concurrent reads remain serialized and paced even after a failed request',async()=>{
 let time=0,active=0,maxActive=0;const starts=[];
 const rpc=createRpcRequest({rpcUrl:'http://localhost',chainId:1,rpcPaceMs:750},{now:()=>time,sleep:async ms=>{time+=ms;},fetch:async()=>{
  starts.push(time);maxActive=Math.max(maxActive,++active);await Promise.resolve();active--;
  return {ok:true,json:async()=>({result:'ok'})};
 }});
 assert.deepEqual(await Promise.all([1,2,3].map(()=>rpc.request({method:'eth_blockNumber'}))),['ok','ok','ok']);
 assert.equal(maxActive,1);assert.deepEqual(starts,[0,750,1500]);
});

test('retry exhaustion is bounded and a new read still succeeds',async()=>{
 let time=0,broken=true,calls=0;
 const rpc=createRpcRequest({rpcUrl:RH_RPC_URLS[0],chainId:4663},{now:()=>time,sleep:async ms=>{time+=ms;},fetch:async()=>{calls++;return broken?{ok:false,status:403}:{ok:true,json:async()=>({result:'ok'})};}});
 await assert.rejects(rpc.request({method:'eth_blockNumber'}),e=>e.rpcExhausted&&e.message==='RPC retry budget exhausted');
 assert.equal(calls,8);assert.ok(time>=120000&&time<=180000);broken=false;
 assert.equal(await rpc.request({method:'eth_blockNumber'}),'ok');
});

test('range refusal is surfaced immediately for adaptive splitting',async()=>{
 let calls=0;
 const rpc=createRpcRequest({rpcUrl:'http://localhost',chainId:1},{fetch:async()=>{calls++;return {ok:true,json:async()=>({error:{code:-32005,message:'query returned more than 10000 results'}})};}});
 await assert.rejects(rpc.request({method:'eth_getLogs'}),e=>e.logRange===true);assert.equal(calls,1);
});
