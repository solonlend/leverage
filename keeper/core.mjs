import { writeFile } from 'node:fs/promises';

const ZERO = '0x' + '0'.repeat(40);

export function sleep(ms, signal) {
  return new Promise(resolve => {
    if (signal?.aborted) return resolve();
    const done = () => { clearTimeout(timer); signal?.removeEventListener('abort', done); resolve(); };
    const timer = setTimeout(done, ms);
    signal?.addEventListener('abort', done, { once: true });
  });
}

export async function retryRead(operation, config, signal) {
  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw Error('stopping');
    try { return await operation(); } catch {
      if (attempt >= config.retries) throw Error('read failed');
      await sleep(config.retryDelayMs * (attempt + 1), signal);
    }
  }
}

export async function scanOnce(vault, config, { log = console.log, signal, now = Date.now } = {}) {
  const stats = { scanned: 0, active: 0, unhealthy: 0, failed: 0 };
  const read = fn => retryRead(fn, config, signal);
  try {
    const next = await read(() => vault.nextPositionId());
    for (let id = 1n; id < next; id++) {
      if (signal?.aborted) break;
      stats.scanned++;
      try {
        if ((await read(() => vault.ownerOf(id))).toLowerCase() === ZERO) continue;
        stats.active++;
        if (await read(() => vault.isHealthy(id))) continue;
        stats.unhealthy++;
        if (signal?.aborted) break;
        if (config.dryRun !== false) log(`would liquidate #${id} (health false)`);
        else {
          // Never retry a write: a timeout may mean the transaction was accepted.
          await vault.liquidate(id, {
            ratioBps: config.ratioBps,
            minSeizeValue: config.minSeizeValue,
            deadline: BigInt(Math.floor(now() / 1000) + config.deadlineSeconds),
          });
          log(`liquidated #${id}`);
        }
      } catch (error) {
        stats.failed++;
        const reason = error?.code === 'BROADCAST_UNCERTAIN'
          ? 'BROADCAST_UNCERTAIN: writes paused; reconcile account transactions before restart'
          : 'failed; continuing';
        log(`position #${id} ${reason}`);
      }
    }
    // Successful full scan → refresh the keeper heartbeat the monitor reads (best-effort; a write
    // failure must never disrupt the keeper). Only here, so a failed round leaves the heartbeat stale.
    if (config.heartbeatFile) {
      try {
        await writeFile(config.heartbeatFile, JSON.stringify({ updatedAt: Math.floor(now() / 1000) }));
      } catch { /* heartbeat is advisory; ignore write failures */ }
    }
  } catch {
    stats.failed++;
    log('round read failed; retrying next round');
  } finally {
    log(`${new Date().toISOString()} heartbeat scanned=${stats.scanned} active=${stats.active} unhealthy=${stats.unhealthy} failed=${stats.failed}`);
  }
  return stats;
}

export async function runKeeper(vault, config, options = {}) {
  while (!options.signal?.aborted) {
    await scanOnce(vault, config, options);
    if (config.once || options.signal?.aborted) break;
    await sleep(config.pollIntervalMs, options.signal);
  }
}
