const UINT256_MAX = (1n << 256n) - 1n;
function uint(env, name, fallback, min, max) {
  const raw = env[name] ?? fallback;
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) throw Error(`Invalid ${name}`);
  const value = BigInt(raw);
  if (value < min || value > max) throw Error(`Invalid ${name}`);
  return value;
}
export function readConfig(env = process.env) {
  if (env.DRY_RUN !== undefined && !['true', 'false'].includes(env.DRY_RUN)) throw Error('Invalid DRY_RUN');
  const dryRun = env.DRY_RUN !== 'false';
  try {
    if (!['http:', 'https:'].includes(new URL(env.RPC_URL).protocol)) throw Error();
  } catch { throw Error('Invalid RPC_URL'); }
  if (!/^0x[0-9a-fA-F]{40}$/.test(env.VAULT_ADDRESS ?? '') || /^0x0{40}$/.test(env.VAULT_ADDRESS)) throw Error('Invalid VAULT_ADDRESS');
  const minSeizeValue = uint(env, 'MIN_SEIZE_VALUE', dryRun ? '0' : undefined, dryRun ? 0n : 1n, UINT256_MAX);
  if (!dryRun && !/^0x[0-9a-fA-F]{64}$/.test(env.KEEPER_PRIVATE_KEY ?? '')) throw Error('Invalid KEEPER_PRIVATE_KEY');
  return {
    dryRun, rpcUrl: env.RPC_URL, vaultAddress: env.VAULT_ADDRESS,
    minSeizeValue,
    ratioBps: uint(env, 'RATIO_BPS', '5000', 1n, 10000n),
    pollIntervalMs: Number(uint(env, 'POLL_INTERVAL_MS', '30000', 1n, 2147483647n)),
    retries: Number(uint(env, 'RPC_RETRIES', '3', 0n, 10n)),
    retryDelayMs: Number(uint(env, 'RETRY_DELAY_MS', '1000', 1n, 60000n)),
    rpcTimeoutMs: Number(uint(env, 'RPC_TIMEOUT_MS', '10000', 1n, 60000n)),
    receiptTimeoutMs: Number(uint(env, 'RECEIPT_TIMEOUT_MS', '60000', 1n, 300000n)),
    deadlineSeconds: Number(uint(env, 'DEADLINE_SECONDS', '120', 1n, 3600n)),
    // Optional: path where a successful scan writes {updatedAt} for the monitor's keeper-liveness
    // check. Unset (default) => no heartbeat file, unchanged behaviour.
    heartbeatFile: env.HEARTBEAT_FILE || undefined,
  };
}
