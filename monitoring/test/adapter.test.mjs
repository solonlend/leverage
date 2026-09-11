import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readConfig} from '../config.mjs';
import {createChain,abi,badDebtEvent} from '../adapter.mjs';
const env={RPC_URL:'http://localhost:8545',VAULT:'0x'+'1'.repeat(40),START_BLOCK:'1'};
test('config uses runbook RH addresses and validates required fields',()=>{const c=readConfig(env);assert.equal(c.chainId,4663);assert.equal(c.startBlock,1n);assert.equal(c.pollMs,60000);assert.throws(()=>readConfig({...env,START_BLOCK:''}));assert.throws(()=>readConfig({...env,VAULT:'bad'}));assert.throws(()=>readConfig({...env,MONITOR_LOG:'/tmp/outside'}));assert.throws(()=>readConfig({...env,POLL_MS:'0'}));assert.throws(()=>readConfig({...env,TELEGRAM_BOT_TOKEN:'fake'}));});
test('viem ABI can decode actual BadDebt layout offline',()=>{const require=createRequire(new URL('../../keeper/package.json',import.meta.url));const v=require('viem');const topics=v.encodeEventTopics({abi:[badDebtEvent],eventName:'BadDebt',args:{id:1n,debtId:2n}});const decoded=v.decodeEventLog({abi:[badDebtEvent],topics,data:v.encodeAbiParameters([{type:'uint256'}],[3n])});assert.equal(decoded.args.residualDebt,3n);assert.ok(abi.length>0);});
test('chain adapter pins calls and filters logs by vault',async()=>{const calls=[];const client={getBlockNumber:async()=>7n,readContract:async r=>{calls.push(r);return r.functionName==='ownerOf'?'0x'+'0'.repeat(40):r.functionName==='decimals'?8:[];},getLogs:async r=>{calls.push(r);return [];}};const c=readConfig(env);const chain=createChain(client,c);await chain.feed('ETH');assert.equal(calls[0].blockNumber,7n);assert.equal(calls[0].address,c.ethFeed);assert.equal(await chain.position(1n),null);await chain.badDebt(1n,2n);assert.equal(calls.at(-1).address,c.vault);assert.equal(calls.at(-1).strict,true);});

test('log scan shrinks rejected ranges and covers every block exactly once',async()=>{
 const accepted=[],attempted=[];
 const client={getLogs:async r=>{attempted.push([r.fromBlock,r.toBlock]);if(r.toBlock-r.fromBlock>=3n)throw Error('block range exceeds limit');accepted.push([r.fromBlock,r.toBlock]);return [{blockNumber:r.fromBlock}];}};
 const chain=createChain(client,{vault:env.VAULT,logBlockRange:8n});
 const logs=await chain.badDebt(1n,12n);
 assert.ok(attempted.every(([a,b])=>b-a<8n));
 assert.deepEqual(accepted.flatMap(([a,b])=>Array.from({length:Number(b-a+1n)},(_,i)=>a+BigInt(i))),Array.from({length:12},(_,i)=>BigInt(i+1)));
 assert.equal(logs.length,accepted.length);
});
