// Solon Range Vaults (CLM) keeper: moveTicks 巡逻 + 运维告警,单文件自足(viem)。
// 触发条件(满足其一且 isCalm):①距上次调仓 > MOVE_INTERVAL_S(默认 6h)②现价 tick 出了主仓区间。
// 告警(stdout+可选 TG):出区间持续且不平静无法调仓、moveTicks 失败、RPC 连续失败。
// 心跳:每次成功扫描写 HEARTBEAT_FILE(供 monitoring daemon 的 keeper-liveness 检查)。
//
// env: RPC_URL, STRATEGY_ADDRESS, POOL_ADDRESS, DRY_RUN(默认 true), KEEPER_PRIVATE_KEY(实弹必填),
//      CHAIN_ID(默认 4663), MOVE_INTERVAL_S(21600), OOR_ALERT_S(1800), POLL_MS(120000),
//      HEARTBEAT_FILE, TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID(可选)
import { createPublicClient, createWalletClient, http, defineChain } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { writeFile, appendFile } from 'node:fs/promises';

const env = process.env;
const dryRun = env.DRY_RUN !== 'false';
const rpcUrl = env.RPC_URL;
const strategyAddr = env.STRATEGY_ADDRESS;
const poolAddr = env.POOL_ADDRESS;
const chainId = Number(env.CHAIN_ID ?? '4663');
const moveIntervalS = Number(env.MOVE_INTERVAL_S ?? '21600');
const oorAlertS = Number(env.OOR_ALERT_S ?? '1800');
const pollMs = Number(env.POLL_MS ?? '120000');
const heartbeatFile = env.HEARTBEAT_FILE;
if (!rpcUrl || !/^0x[0-9a-fA-F]{40}$/.test(strategyAddr ?? '') || !/^0x[0-9a-fA-F]{40}$/.test(poolAddr ?? '')) {
  console.error('need RPC_URL, STRATEGY_ADDRESS, POOL_ADDRESS'); process.exit(1);
}
if (!dryRun && !/^0x[0-9a-fA-F]{64}$/.test(env.KEEPER_PRIVATE_KEY ?? '')) {
  console.error('live mode needs KEEPER_PRIVATE_KEY'); process.exit(1);
}

const chain = defineChain({ id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } });
const pub = createPublicClient({ chain, transport: http(rpcUrl, { timeout: 10_000 }) });
const wallet = dryRun ? undefined : createWalletClient({ account: privateKeyToAccount(env.KEEPER_PRIVATE_KEY), chain, transport: http(rpcUrl, { timeout: 15_000 }) });

const stratAbi = [
  { type: 'function', name: 'positionMain', stateMutability: 'view', inputs: [], outputs: [{ type: 'int24' }, { type: 'int24' }] },
  { type: 'function', name: 'lastPositionAdjustment', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'isCalm', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'moveTicks', stateMutability: 'nonpayable', inputs: [], outputs: [] },
];
const poolAbi = [
  { type: 'function', name: 'slot0', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint160' }, { type: 'int24' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'uint8' }, { type: 'bool' }] },
];

const log = async (level, msg) => {
  const line = JSON.stringify({ time: new Date().toISOString(), level, msg }) + '\n';
  process.stdout.write(line);
  if (env.LOG_FILE) { try { await appendFile(env.LOG_FILE, line, { mode: 0o600 }); } catch {} }
  if ((level === 'alert' || level === 'error') && env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    try {
      await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text: `SOLON RANGE-KEEPER [${level}] ${msg}` }),
        signal: AbortSignal.timeout(10_000),
      });
    } catch {}
  }
};

let oorSince = 0;       // 出区间起始时刻(0=在区间)
let rpcFailStreak = 0;
let lastOorAlert = 0;
const ALERT_COOLDOWN_MS = 30 * 60 * 1000;

async function scan() {
  const [main, lastAdj, calm, isPaused, slot0] = await Promise.all([
    pub.readContract({ address: strategyAddr, abi: stratAbi, functionName: 'positionMain' }),
    pub.readContract({ address: strategyAddr, abi: stratAbi, functionName: 'lastPositionAdjustment' }),
    pub.readContract({ address: strategyAddr, abi: stratAbi, functionName: 'isCalm' }),
    pub.readContract({ address: strategyAddr, abi: stratAbi, functionName: 'paused' }),
    pub.readContract({ address: poolAddr, abi: poolAbi, functionName: 'slot0' }),
  ]);
  rpcFailStreak = 0;
  const [lower, upper] = main;
  const tick = slot0[1];
  const now = Math.floor(Date.now() / 1000);
  const inRange = tick >= lower && tick <= upper;
  const stale = now - Number(lastAdj) > moveIntervalS;

  if (inRange) oorSince = 0;
  else if (oorSince === 0) oorSince = now;

  if (heartbeatFile) { try { await writeFile(heartbeatFile, JSON.stringify({ updatedAt: now }), { mode: 0o600 }); } catch {} }

  if (isPaused) { await log('info', `paused; skip (tick=${tick} range=[${lower},${upper}])`); return; }

  const needMove = stale || !inRange;
  if (!needMove) { await log('info', `ok tick=${tick} range=[${lower},${upper}] ageS=${now - Number(lastAdj)}`); return; }

  if (!calm) {
    const oorDur = oorSince ? now - oorSince : 0;
    if (oorDur > oorAlertS && Date.now() - lastOorAlert > ALERT_COOLDOWN_MS) {
      lastOorAlert = Date.now();
      await log('alert', `out-of-range ${oorDur}s and NOT calm — cannot moveTicks yet (tick=${tick} range=[${lower},${upper}])`);
    } else {
      await log('info', `move needed but not calm (tick=${tick} range=[${lower},${upper}])`);
    }
    return;
  }

  if (dryRun) { await log('info', `WOULD moveTicks (stale=${stale} inRange=${inRange} tick=${tick} range=[${lower},${upper}])`); return; }

  try {
    const hash = await wallet.writeContract({ address: strategyAddr, abi: stratAbi, functionName: 'moveTicks' });
    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (rcpt.status === 'success') { oorSince = 0; await log('info', `moveTicks ok ${hash}`); }
    else await log('alert', `moveTicks reverted ${hash}`);
  } catch (e) {
    await log('alert', `moveTicks failed: ${String(e.message ?? e).slice(0, 160)}`);
  }
}

await log('info', `range keeper up: strategy=${strategyAddr} chain=${chainId} dryRun=${dryRun} moveIntervalS=${moveIntervalS}`);
for (;;) {
  try { await scan(); }
  catch (e) {
    rpcFailStreak += 1;
    if (rpcFailStreak === 5) await log('alert', `rpc failing x5: ${String(e.message ?? e).slice(0, 120)}`);
    else await log('warn', `scan failed: ${String(e.message ?? e).slice(0, 120)}`);
  }
  await new Promise(r => setTimeout(r, pollMs));
}
