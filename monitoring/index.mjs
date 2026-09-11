import {createRequire} from 'node:module';
import {mkdir,open,readFile,rename,unlink,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as sleep} from 'node:timers/promises';
import {readConfig} from './config.mjs';
import {createChain} from './adapter.mjs';
import {createRpcRequest} from './rpc.mjs';
import {createMonitor,retryRead} from './monitor.mjs';
import {createNotifier,createAlertGate} from './notify.mjs';

export async function run({config=readConfig(),client,once=false,dryRun=false,signal,notify}={}) {
  if(dryRun&&!once)throw Error('dry-run requires --once');
  const alerts=[];let dryState;
  if(dryRun)notify=async(level,msg)=>{alerts.push({level,msg});return true;};
  else {
    await mkdir(dirname(config.stateFile),{recursive:true,mode:0o700});
    await mkdir(dirname(config.logFile),{recursive:true,mode:0o700});
    notify??=createNotifier({logFile:config.logFile,token:config.token,chatId:config.chatId});
  }
  const lockFile=config.stateFile+'.lock';
  const lock=dryRun?undefined:await open(lockFile,'wx',0o600);
  let monitor;
  try {
    await lock?.writeFile(String(process.pid));
    if(!client) {
      // Resolve existing keeper installation directly; no install or symlink required.
      const require=createRequire(new URL('../keeper/package.json',import.meta.url));
      const {createPublicClient,custom}=require('viem');
      client=createPublicClient({transport:custom(createRpcRequest({...config,signal}),{retryCount:0}),cacheTime:0});
    }
    if(await retryRead(()=>client.getChainId(),{...config,signal})!==config.chainId)throw Error('wrong chain');
    const alert=createAlertGate({notify,cooldownMs:config.cooldownMs});
    monitor=createMonitor({chain:createChain(client,config),config,alert,clear:alert.clear,signal,
      readHeartbeat:async()=>JSON.parse(await readFile(config.heartbeatFile,'utf8')),
      loadState:async()=>{if(dryRun)return dryState;try{return JSON.parse(await readFile(config.stateFile,'utf8'));}catch(e){if(e.code==='ENOENT')return undefined;throw Error('invalid state');}},
      saveState:async state=>{
        if(dryRun){dryState=state;return;}
        const tmp=config.stateFile+'.tmp';
        await writeFile(tmp,JSON.stringify(state)+'\n',{mode:0o600});
        await rename(tmp,config.stateFile);
      },
    });
    await notify('info','Monitor started: read-only feed, keeper and BadDebt checks enabled');
    while(!signal?.aborted) {
      const started=Date.now();
      await monitor.tick({wait:once});
      if(once||signal?.aborted)break;
      const elapsed=Date.now()-started;
      try {await sleep(Math.max(1,config.pollMs-elapsed),undefined,{signal});}catch(e){if(e.name!=='AbortError')throw e;}
    }
    return {chainId:config.chainId,vault:config.vault,checks:monitor.results,...(dryRun?{dryRun:true,alerts}:{})};
  } finally {
    // Keep the instance lock until active reads/deliveries finish. Aborted batches stop at the next boundary.
    await monitor?.drain();
    if(lock){await lock.close();await unlink(lockFile);}
  }
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  const controller=new AbortController();
  for(const name of ['SIGINT','SIGTERM'])process.once(name,()=>controller.abort());
  const args=process.argv.slice(2);
  const main=async()=>{
    if(args.some(a=>!['--once','--dry-run'].includes(a)))throw Error('unsupported flag');
    const dryRun=args.includes('--dry-run');
    const result=await run({once:args.includes('--once'),dryRun,signal:controller.signal});
    if(dryRun){process.stdout.write(JSON.stringify(result)+'\n');if(!result.checks.events?.ok)process.exitCode=1;}
  };
  main().catch(()=>{process.stderr.write('Monitor failed: check configuration, dependencies, RPC or instance lock; details suppressed.\n');process.exitCode=1;});
}
