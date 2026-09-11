import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createChain,abi,badDebtEvent} from '../adapter.mjs';
const require=createRequire(new URL('../../keeper/package.json',import.meta.url));
const {createPublicClient,custom,decodeFunctionData,encodeFunctionResult,encodeEventTopics,encodeAbiParameters}=require('viem');
test('real viem public client decodes mocked JSON-RPC feed/position/BadDebt',async()=>{
 const address='0x'+'1'.repeat(40),hash='0x'+'2'.repeat(64),methods=[];
 const results={latestRoundData:[1n,100300000n,0n,1000n,1n],decimals:8,ownerOf:address,positionValue:100n,totalDebtInLoan:91n,LLTV:10n**18n,nextPositionId:2n};
 const client=createPublicClient({cacheTime:0,transport:custom({request:async({method,params})=>{
   methods.push(method);
   if(method==='eth_blockNumber')return '0x10';
   if(method==='eth_call'){
     const {functionName}=decodeFunctionData({abi,data:params[0].data});
     return encodeFunctionResult({abi,functionName,result:results[functionName]});
   }
   if(method==='eth_getLogs')return [{address,blockHash:hash,blockNumber:'0x10',transactionHash:hash,transactionIndex:'0x0',logIndex:'0x0',removed:false,topics:encodeEventTopics({abi:[badDebtEvent],eventName:'BadDebt',args:{id:1n,debtId:2n}}),data:encodeAbiParameters([{type:'uint256'}],[3n])}];
   throw Error('unexpected RPC method');
 }},{retryCount:0})});
 const chain=createChain(client,{vault:address,ethFeed:address,usdgFeed:address});
 assert.deepEqual(await chain.feed('USDG'),{round:results.latestRoundData,decimals:8});
 assert.deepEqual(await chain.position(1n),{value:100n,debt:91n});
 assert.equal(await chain.nextPositionId(),2n);assert.equal(await chain.lltv(),10n**18n);
 const events=await chain.badDebt(1n,16n);assert.deepEqual(events[0].args,{id:1n,debtId:2n,residualDebt:3n});
 assert.ok(methods.every(m=>['eth_blockNumber','eth_call','eth_getLogs'].includes(m)));
});

test('transport exhaustion wrapped by viem never starts another monitor retry budget',async()=>{
 const {createRpcRequest}=await import('../rpc.mjs');const {retryRead}=await import('../monitor.mjs');
 let time=0,calls=0;
 const rpc=createRpcRequest({rpcUrl:'https://rpc.mainnet.chain.robinhood.com/rpc',chainId:4663},{now:()=>time,sleep:async ms=>{time+=ms;},fetch:async()=>{calls++;return {ok:false,status:403};}});
 const client=createPublicClient({cacheTime:0,transport:custom(rpc,{retryCount:0})});
 await assert.rejects(retryRead(()=>client.getBlockNumber(),{retries:2,retryDelayMs:0}),/read failed/);
 assert.equal(calls,8);assert.ok(time<=180000);
});
