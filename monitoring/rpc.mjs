import {setTimeout as delay} from 'node:timers/promises';
export const RH_RPC_URLS=[
  'https://rpc.mainnet.chain.robinhood.com/rpc',
  'https://robinhood-rpc.publicnode.com',
  'https://rpc.mainnet.chain.robinhood.com',
];
const browserUA='Mozilla/5.0 (compatible; SolonReadOnlyMonitor/1.0)';
export function isLogRangeError(error) {
  for(let e=error;e;e=e.cause) if(e.logRange || /block range|range.{0,30}(large|limit|exceed)|too many (results|logs)|query returned more/i.test(`${e.message??''} ${e.details??''}`))return true;
  return false;
}
export function isRpcExhausted(error) {
  for(let e=error;e;e=e.cause)if(e.rpcExhausted)return true;
  return false;
}
// One shared queue paces the monitor's concurrent feed/event reads and cooldowns.
export function createRpcRequest(config,{fetch:fetchImpl=globalThis.fetch,sleep=ms=>delay(ms,undefined,{signal:config.signal}),now=Date.now}={}) {
  const urls=[...new Set([config.rpcUrl,...(config.chainId===4663?RH_RPC_URLS:[])])];
  const pace=config.rpcPaceMs??1000,budget=config.rpcRetryBudgetMs??180000;
  const retries=config.rpcTransportRetries??7;
  let endpoint=0,nextCall=0,queue=Promise.resolve(),id=0;
  async function perform({method,params}) {
    const deadline=now()+budget;
    for(let attempt=0;;attempt++) {
      if(config.signal?.aborted)throw Error('monitor stopped');
      if(nextCall>now())await sleep(nextCall-now());
      const remaining=deadline-now();
      if(remaining<=0)break;
      const timeout=AbortSignal.timeout(Math.max(1,Math.min(config.rpcTimeoutMs??10000,remaining)));
      const signal=config.signal?AbortSignal.any([timeout,config.signal]):timeout;
      try {
        const response=await fetchImpl(urls[endpoint],{method:'POST',headers:{'Content-Type':'application/json','User-Agent':browserUA},
          body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params}),signal});
        if(!response.ok) {
          // Drain the response so failed requests don't leave connections occupied.
          await response.body?.cancel();
          const error=Error('RPC HTTP request failed');
          error.retryable=[403,408,429,500,502,503,504].includes(response.status);throw error;
        }
        const body=await response.json();
        if(body.error) {
          const error=Error('RPC response failed');
          error.logRange=method==='eth_getLogs'&&isLogRangeError(body.error);
          error.retryable=body.error.code===429 || /rate|throttl|too many requests|temporar|limit exceeded/i.test(body.error.message??'');
          throw error;
        }
        if(!Object.hasOwn(body,'result'))throw Object.assign(Error('invalid RPC response'),{retryable:false});
        return body.result;
      } catch(error) {
        if(config.signal?.aborted)throw Error('monitor stopped');
        if(error.logRange)throw error;
        if(error.retryable===false)throw error;
        if(attempt>=retries)break;
        const backoff=Math.min(2000*2**attempt,45000);
        if(now()+backoff>=deadline)break;
        endpoint=(endpoint+1)%urls.length;
        await sleep(backoff);
      } finally {nextCall=now()+pace;}
    }
    throw Object.assign(Error('RPC retry budget exhausted'),{rpcExhausted:true});
  }
  return {request(args) {
    const task=queue.then(()=>perform(args));
    queue=task.catch(()=>{});
    return task;
  }};
}
