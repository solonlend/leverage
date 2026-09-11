import {dirname,resolve,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
export const root=dirname(fileURLToPath(import.meta.url));
export function readConfig(env=process.env) {
  const number=(name,fallback,min,max)=>{const raw=env[name]??String(fallback);if(!/^\d+$/.test(raw))throw Error('invalid config');const n=Number(raw);if(!Number.isSafeInteger(n)||n<min||n>max)throw Error('invalid config');return n;};
  const address=(name,fallback)=>{const v=env[name]??fallback;if(!/^0x[0-9a-fA-F]{40}$/.test(v??'')||/^0x0{40}$/.test(v))throw Error('invalid address');return v;};
  const output=(name,fallback)=>{const p=resolve(root,env[name]??fallback);if(!p.startsWith(root+sep))throw Error('output outside monitoring');return p;};
  const rpcUrl=env.RPC_URL;const url=new URL(rpcUrl);if(!['https:','http:'].includes(url.protocol))throw Error('invalid RPC');
  if(!/^\d+$/.test(env.START_BLOCK??''))throw Error('START_BLOCK required');
  if(Boolean(env.TELEGRAM_BOT_TOKEN)!==Boolean(env.TELEGRAM_CHAT_ID))throw Error('incomplete Telegram config');
  if(env.HEALTH_ENABLED!==undefined&&!['true','false'].includes(env.HEALTH_ENABLED))throw Error('invalid boolean');
  const vault=address('VAULT');const chainId=number('CHAIN_ID',4663,1,Number.MAX_SAFE_INTEGER);
  return {rpcUrl,vault,chainId,startBlock:BigInt(env.START_BLOCK),
    // OPS-RUNBOOK §1; deployments on other chains must override both feeds.
    ethFeed:address('ETH_FEED','0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9'),
    usdgFeed:address('USDG_FEED','0x61B7e5650328764B076A108EFF5fa7282a1B9aD2'),
    pollMs:number('POLL_MS',60000,100,60000),rpcTimeoutMs:number('RPC_TIMEOUT_MS',5000,100,30000),
    retries:number('RPC_RETRIES',2,0,5),retryDelayMs:number('RPC_RETRY_DELAY_MS',250,0,5000),
    blockBatch:BigInt(number('BLOCK_BATCH',1000,1,10000)),confirmations:BigInt(number('CONFIRMATIONS',0,0,1000)),
    cooldownMs:number('COOLDOWN_MS',300000,1,86400000),healthEnabled:env.HEALTH_ENABLED==='true',
    // Keeper heartbeat check: on by default; set HEARTBEAT_ENABLED=false until the keeper writes a heartbeat file (else it false-alarms every cycle).
    heartbeatEnabled:env.HEARTBEAT_ENABLED!=='false',
    maxPositions:number('MAX_POSITIONS',1000,1,100000),nearCount:number('NEAR_COUNT',5,1,100000),
    heartbeatFile:resolve(root,env.HEARTBEAT_FILE??'runtime/keeper-heartbeat.json'),
    logFile:output('MONITOR_LOG','runtime/alerts.jsonl'),stateFile:output('STATE_FILE','runtime/events.json'),
    token:env.TELEGRAM_BOT_TOKEN,chatId:env.TELEGRAM_CHAT_ID,
    scope:`${chainId}:${vault.toLowerCase()}:${env.START_BLOCK}`};
}
