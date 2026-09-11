import {isRpcExhausted,isLogRangeError} from './rpc.mjs';
import {setTimeout as sleep} from 'node:timers/promises';
import {feedAlerts,heartbeatAlert,nearLiquidation} from './rules.mjs';
export async function retryRead(operation,{retries,retryDelayMs,signal}) {
  for(let attempt=0;;attempt++) {
    if(signal?.aborted) throw Error('monitor stopped');
    try {return await operation();} catch(error) {
      if(signal?.aborted) throw Error('monitor stopped');
      if(isRpcExhausted(error)||isLogRangeError(error)||attempt>=retries) throw Error('read failed');
      await sleep(retryDelayMs*(attempt+1),undefined,{signal});
    }
  }
}
export function createMonitor({chain,config,alert,clear,readHeartbeat,loadState,saveState,signal,now=()=>Math.floor(Date.now()/1000)}) {
  const checkStopped=()=>{if(signal?.aborted)throw Error('monitor stopped');};
  const read=async fn=>{checkStopped();const result=await retryRead(fn,{...config,signal});checkStopped();return result;};
  async function send(a) {checkStopped();return alert(a.key,a.level,a.msg);}
  const results={};
  async function isolated(name,fn) {
    try {const details=await fn();results[name]={ok:true,...details};clear(`check:${name}`);}
    catch {results[name]={ok:false};if(signal?.aborted)return;await alert(`check:${name}`,'critical',`${name} check failed: data unavailable; investigate (details suppressed)`);}
  }
  async function feed(name) {
    const {round,decimals}=await read(()=>chain.feed(name));
    const alerts=feedAlerts(name,round,decimals,now());
    for(const suffix of ['invalid','stale','peg']) if(!alerts.some(a=>a.key===`${name}:${suffix}`)) clear(`${name}:${suffix}`);
    for(const a of alerts) await send(a);
  }
  async function events() {
    const state=await loadState();
    checkStopped();
    if(state && (state.scope!==config.scope || !/^\d+$/.test(state.nextBlock) || BigInt(state.nextBlock)<config.startBlock)) throw Error('invalid cursor');
    let from=state?BigInt(state.nextBlock):config.startBlock;
    if(state && await read(()=>chain.blockHash(from-1n))!==state.hash) throw Error('reorg: manual rewind required');
    const head=await read(()=>chain.head());
    const end=head-config.confirmations;
    if(from>end) return {head:String(head),fromBlock:String(from),toBlock:String(end),logs:0,upToDate:true};
    const to=from+config.blockBatch-1n<end?from+config.blockBatch-1n:end;
    // Verify range anchor on both sides of getLogs to avoid committing a mixed fork.
    const hash=await read(()=>chain.blockHash(to));
    const logs=await read(()=>chain.badDebt(from,to));
    if(await read(()=>chain.blockHash(to))!==hash) throw Error('reorg');
    for(const log of logs) {
      checkStopped();
      const key=`BadDebt:${log.transactionHash}:${log.logIndex}`;
      const ok=await alert(key,'critical',`BadDebt block=${log.blockNumber} tx=${log.transactionHash} log=${log.logIndex} id=${log.args.id} debtId=${log.args.debtId} residualDebt=${log.args.residualDebt}`);
      if(ok===false) throw Error('delivery failed');
    }
    checkStopped();
    await saveState({scope:config.scope,nextBlock:String(to+1n),hash});
    // Events are deduplicated by durable cursor; don't retain unbounded keys.
    for(const log of logs) clear(`BadDebt:${log.transactionHash}:${log.logIndex}`);
    if(to<end) await alert('events:backlog','warn',`BadDebt scan catching up: next=${to+1n} target=${end}`);
    else clear('events:backlog');
    return {head:String(head),fromBlock:String(from),toBlock:String(to),logs:logs.length,upToDate:to===end};
  }
  async function health() {
    const next=await read(()=>chain.nextPositionId());
    if(next<1n || next-1n>BigInt(config.maxPositions)) throw Error('scan limit exceeded');
    const lltv=await read(()=>chain.lltv());
    let count=0;
    for(let id=1n;id<next;id++) {
      const p=await read(()=>chain.position(id));
      if(p && nearLiquidation(p.value,p.debt,lltv)) count++;
    }
    checkStopped();
    if(count>=config.nearCount) await alert('health:count','warn',`Positions above 90% liquidation capacity: count=${count} threshold=${config.nearCount}`);
    else clear('health:count');
  }
  const tasks=[['ETH',()=>feed('ETH')],['USDG',()=>feed('USDG')],
    ...(config.heartbeatEnabled?[['heartbeat',async()=>{const a=heartbeatAlert(await readHeartbeat(),now());if(a)await send(a);else clear('keeper:heartbeat');}]]:[]),
    ['events',events],...(config.healthEnabled?[['health',health]]:[])];
  const busy=new Map();
  const diagnostics=new Map();
  return {
    results,
    async tick({wait=true}={}) {
      if(signal?.aborted)return;
      for(const [name,fn] of tasks) {
        if(busy.has(name)) {
          // A slow-warning delivery is itself bounded to one in-flight attempt.
          if(!diagnostics.has(name)) {
            const warning=Promise.resolve().then(()=>signal?.aborted?false:alert(`slow:${name}`,'warn',`${name} check still running; skipped overlapping poll`))
              .catch(()=>{}).finally(()=>diagnostics.delete(name));
            diagnostics.set(name,warning);
          }
          continue;
        }
        clear(`slow:${name}`);
        const task=isolated(name,fn).finally(()=>busy.delete(name));
        busy.set(name,task);
      }
      if(wait) await this.drain();
    },
    async drain() {await Promise.allSettled([...busy.values(),...diagnostics.values()]);},
  };
}
