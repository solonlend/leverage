import { vaultAbi } from './abi.mjs';

const uncertainError = () => Object.assign(Error('broadcast uncertain; manual reconciliation required'), { code: 'BROADCAST_UNCERTAIN' });

export function createVaultAdapter(publicClient, walletClient, config, signal) {
  let pendingHash;
  let uncertain = false;
  const request = (functionName, args = []) => ({ address: config.vaultAddress, abi: vaultAbi, functionName, args });
  const receipt = hash => publicClient.waitForTransactionReceipt({ hash, timeout: config.receiptTimeoutMs, retryCount: 0 });
  return {
    nextPositionId: () => publicClient.readContract(request('nextPositionId')),
    ownerOf: id => publicClient.readContract(request('ownerOf', [id])),
    isHealthy: id => publicClient.readContract(request('isHealthy', [id])),
    async liquidate(id, params) {
      if (config.dryRun !== false || !walletClient) throw Error('writes disabled');
      if (uncertain) throw uncertainError();
      if (pendingHash) {
        await receipt(pendingHash);
        pendingHash = undefined;
        throw Error('pending transaction reconciled; rescan before another write');
      }
      const { request: simulated } = await publicClient.simulateContract({
        ...request('liquidate', [id, params]), account: walletClient.account,
      });
      if (signal?.aborted) throw Error('stopping');
      try { pendingHash = await walletClient.writeContract(simulated); }
      catch { uncertain = true; throw uncertainError(); }
      const mined = await receipt(pendingHash);
      pendingHash = undefined;
      if (mined.status !== 'success') throw Error('liquidation reverted');
    },
  };
}
