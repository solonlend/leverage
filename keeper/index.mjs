import { readConfig } from './config.mjs';
import { createVaultAdapter } from './adapter.mjs';
import { runKeeper, retryRead } from './core.mjs';

const controller = new AbortController();
for (const event of ['SIGINT', 'SIGTERM']) {
  process.on(event, () => {
    console.log(`${new Date().toISOString()} stopping; waiting for bounded in-flight RPC`);
    controller.abort();
  });
}
try {
  const config = readConfig();
  const flags = process.argv.slice(2);
  if (flags.some(flag => flag !== '--once')) throw Error('unsupported flag');
  config.once = flags.includes('--once');
  const { createPublicClient, createWalletClient, http } = await import('viem');
  // Disable transport retries, especially for eth_sendRawTransaction. Reads retry in core.
  const transport = http(config.rpcUrl, { timeout: config.rpcTimeoutMs, retryCount: 0 });
  const publicClient = createPublicClient({ transport });
  let walletClient;
  if (!config.dryRun) {
    const { privateKeyToAccount } = await import('viem/accounts');
    const account = privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY);
    const chainId = await retryRead(() => publicClient.getChainId(), config, controller.signal);
    walletClient = createWalletClient({ account, transport, chain: {
      id: chainId, name: 'Keeper RPC chain', nativeCurrency: { name: 'Gas', symbol: 'ETH', decimals: 18 },
      rpcUrls: { default: { http: [config.rpcUrl] } },
    } });
  }
  console.log(`${new Date().toISOString()} mode=${config.dryRun ? 'DRY_RUN' : 'LIVE'}`);
  await runKeeper(createVaultAdapter(publicClient, walletClient, config, controller.signal), config,
    { signal: controller.signal });
} catch {
  // RPC/library error objects can contain URLs, signed payloads or credentials.
  console.error('Keeper startup failed. Check dependencies, environment and RPC; sensitive details suppressed.');
  process.exitCode = 1;
}
