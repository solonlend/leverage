import test from 'node:test';
import assert from 'node:assert/strict';
import { createVaultAdapter } from '../adapter.mjs';
const config = { dryRun: false, vaultAddress: '0x' + '1'.repeat(40), receiptTimeoutMs: 10 };
test('live simulates and sends once; ambiguous broadcast blocks subsequent writes', async () => {
  let writes = 0;
  const publicClient = { simulateContract: async req => ({ request: req }) };
  const walletClient = { account: {}, writeContract: async () => { writes++; throw Error('secret'); } };
  const vault = createVaultAdapter(publicClient, walletClient, config);
  await assert.rejects(vault.liquidate(1n, {}));
  await assert.rejects(vault.liquidate(2n, {}), /uncertain/);
  assert.equal(writes, 1);
});
test('receipt timeout tracks pending transaction and resumes only after receipt', async () => {
  let writes = 0, polls = 0;
  const publicClient = {
    simulateContract: async request => ({ request }),
    waitForTransactionReceipt: async () => { if (++polls === 1) throw Error(); return { status: 'success' }; },
  };
  const walletClient = { account: {}, writeContract: async () => { writes++; return '0xhash'; } };
  const vault = createVaultAdapter(publicClient, walletClient, config);
  await assert.rejects(vault.liquidate(1n, {}));
  // Reconciliation consumes this attempt, preventing a duplicate liquidation of #1.
  await assert.rejects(vault.liquidate(1n, {}), /reconciled/);
  assert.equal(writes, 1);
  await vault.liquidate(2n, {});
  assert.equal(writes, 2);
});
test('dry adapter cannot write even if called directly', async () => {
  const vault = createVaultAdapter({}, null, { ...config, dryRun: true });
  await assert.rejects(vault.liquidate(1n, {}), /disabled/);
});
