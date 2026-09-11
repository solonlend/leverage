import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {root,readConfig} from '../config.mjs';
import {run} from '../index.mjs';
test('daemon once wires checks, writes persistent state and releases lock offline',async()=>{
 const dir=await mkdtemp(join(root,'test-runtime-'));
 try {
 const config=readConfig({RPC_URL:'http://localhost:8545',VAULT:'0x'+'1'.repeat(40),START_BLOCK:'1',STATE_FILE:join(dir,'state.json'),MONITOR_LOG:join(dir,'alerts.jsonl'),HEARTBEAT_FILE:join(dir,'beat.json')});
 await writeFile(config.heartbeatFile,JSON.stringify({updatedAt:Math.floor(Date.now()/1000)}));
 const messages=[];
 const client={getChainId:async()=>4663,getBlockNumber:async()=>1n,getBlock:async()=>({hash:'0x123'}),getLogs:async()=>[],readContract:async({functionName})=>functionName==='decimals'?8:[1n,100000000n,0n,BigInt(Math.floor(Date.now()/1000)),1n]};
 await run({config,client,once:true,notify:async(l,m)=>{messages.push([l,m]);return true;}});
 assert.equal(JSON.parse(await readFile(config.stateFile,'utf8')).nextBlock,'2');
 assert.ok(messages.some(([l,m])=>l==='info'&&m.includes('started')));
 await assert.rejects(readFile(config.stateFile+'.lock'),{code:'ENOENT'});
 } finally {await rm(dir,{recursive:true,force:true});}
});
test('wrong chain fails before polling and cleans lock',async()=>{
 const dir=await mkdtemp(join(root,'test-runtime-'));
 try {const config=readConfig({RPC_URL:'http://localhost',VAULT:'0x'+'1'.repeat(40),START_BLOCK:'0',STATE_FILE:join(dir,'state'),MONITOR_LOG:join(dir,'log')});
 await assert.rejects(run({config,client:{getChainId:async()=>1},once:true,notify:async()=>true}),/wrong chain/);
 await assert.rejects(readFile(config.stateFile+'.lock'),{code:'ENOENT'});
 }finally{await rm(dir,{recursive:true,force:true});}
});

test('daemon keeps polling during slow event scan and drains before releasing its lock',async()=>{
 const dir=await mkdtemp(join(root,'test-runtime-'));
 const controller=new AbortController();let release,resolvePolled;
 const blocked=new Promise(resolve=>{release=resolve;});
 const polled=new Promise(resolve=>{resolvePolled=resolve;});
 let feeds=0,events=0,finished=false;
 const config={...readConfig({RPC_URL:'http://localhost',VAULT:'0x'+'1'.repeat(40),START_BLOCK:'1',STATE_FILE:join(dir,'state'),MONITOR_LOG:join(dir,'log'),HEARTBEAT_FILE:join(dir,'beat')}),pollMs:5};
 await writeFile(config.heartbeatFile,JSON.stringify({updatedAt:Math.floor(Date.now()/1000)}));
 const client={getChainId:async()=>4663,getBlockNumber:async()=>1n,getBlock:async()=>({hash:'hash'}),getLogs:async()=>{events++;await blocked;return [];},readContract:async({functionName})=>{
  if(functionName==='decimals')return 8;
  if(++feeds>=4)resolvePolled(true);
  return [1n,100000000n,0n,BigInt(Math.floor(Date.now()/1000)),1n];
 }};
 const running=run({config,client,signal:controller.signal,notify:async()=>true}).finally(()=>{finished=true;});
 let timer;
 try {
  const observed=await Promise.race([polled,new Promise(resolve=>{timer=setTimeout(()=>resolve(false),150);})]);
  assert.equal(observed,true,'second feed poll must run before getLogs resolves');
  assert.equal(events,1);
  controller.abort();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(finished,false,'shutdown must drain active scan before releasing lock');
  assert.ok(await readFile(config.stateFile+'.lock','utf8'));
 } finally {clearTimeout(timer);controller.abort();release();await running;await rm(dir,{recursive:true,force:true});}
});

test('dry once uses no notifier or durable cursor and reports completed event range',async()=>{
 const dir=await mkdtemp(join(root,'test-runtime-'));
 try {
 const config=readConfig({RPC_URL:'http://localhost',VAULT:'0x'+'1'.repeat(40),START_BLOCK:'1',STATE_FILE:join(dir,'state'),MONITOR_LOG:join(dir,'log'),HEARTBEAT_FILE:join(dir,'missing'),TELEGRAM_BOT_TOKEN:'fake',TELEGRAM_CHAT_ID:'fake'});
 await writeFile(config.stateFile,'production cursor must remain untouched');let notifications=0;
 const client={getChainId:async()=>4663,getBlockNumber:async()=>2n,getBlock:async()=>({hash:'hash'}),getLogs:async()=>[],readContract:async({functionName})=>functionName==='decimals'?8:[1n,100000000n,0n,BigInt(Math.floor(Date.now()/1000)),1n]};
 const result=await run({config,client,once:true,dryRun:true,notify:async()=>{notifications++;return true;}});
 assert.equal(notifications,0);assert.equal(await readFile(config.stateFile,'utf8'),'production cursor must remain untouched');
 assert.equal(result.checks.events.ok,true);assert.equal(result.checks.events.fromBlock,'1');assert.equal(result.checks.events.toBlock,'2');assert.equal(result.checks.events.logs,0);
 assert.equal(result.checks.heartbeat.ok,false);assert.equal(result.alerts.some(a=>a.msg.includes('heartbeat check failed')),true);
 await assert.rejects(readFile(config.logFile),{code:'ENOENT'});
 }finally{await rm(dir,{recursive:true,force:true});}
});
