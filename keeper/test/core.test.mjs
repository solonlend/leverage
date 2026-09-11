import test from 'node:test';
import assert from 'node:assert/strict';
import { scanOnce, runKeeper, sleep } from '../core.mjs';

const zero = '0x' + '0'.repeat(40);
test('dry run skips burned and healthy positions and never sends', async () => {
  const logs = [];
  const checked = [];
  const result = await scanOnce({
    nextPositionId: async () => 4n,
    ownerOf: async id => id === 2n ? zero : '0x' + '1'.repeat(40),
    isHealthy: async id => { checked.push(id); return id === 1n; },
    liquidate: async () => assert.fail('dry run sent a transaction'),
  }, { dryRun: true, retries: 0 }, { log: s => logs.push(s) });
  assert.deepEqual(checked, [1n, 3n]);
  assert.equal(result.scanned, 3);
  assert.ok(logs.some(s => s.includes('would liquidate #3 (health false)')));
  assert.ok(logs.some(s => s.includes('scanned=3')));
});

test('read retry recovers and broken position does not block later liquidation', async () => {
  let attempts = 0;
  const sent = [];
  const logs = [];
  const result = await scanOnce({
    nextPositionId: async () => { if (++attempts === 1) throw Error('secret'); return 4n; },
    ownerOf: async id => { if (id === 1n) throw Error('secret'); return '0x' + '1'.repeat(40); },
    isHealthy: async () => false,
    liquidate: async (id, params) => { sent.push([id, params]); if (id === 2n) throw Error('secret'); },
  }, { dryRun: false, retries: 1, retryDelayMs: 1, ratioBps: 5000n, minSeizeValue: 100n, deadlineSeconds: 60 },
  { log: s => logs.push(s), now: () => 100000 });
  assert.equal(attempts, 2);
  assert.equal(result.failed, 2);
  assert.deepEqual(sent.map(x => x[0]), [2n, 3n]);
  assert.deepEqual(sent[1][1], { ratioBps: 5000n, minSeizeValue: 100n, deadline: 160n });
  assert.ok(!logs.join().includes('secret'));
});

test('empty result emits heartbeat and loop exits on abort', async () => {
  const controller = new AbortController();
  const logs = [];
  await runKeeper({ nextPositionId: async () => 1n }, { pollIntervalMs: 60000, retries: 0 }, {
    signal: controller.signal,
    log: s => { logs.push(s); controller.abort(); },
  });
  assert.equal(logs.length, 1);
  assert.match(logs[0], /scanned=0/);
  await sleep(60000, controller.signal);
});

test('failed round logs heartbeat without exposing RPC error', async () => {
  const logs = [];
  const result = await scanOnce({ nextPositionId: async () => { throw Error('private RPC'); } },
    { retries: 1, retryDelayMs: 1 }, { log: s => logs.push(s) });
  assert.equal(result.failed, 1);
  assert.match(logs.at(-1), /scanned=0/);
  assert.ok(!logs.join().includes('private RPC'));
});

test('uncertain broadcast emits only a safe actionable category', async () => {
  const logs = [];
  await scanOnce({
    nextPositionId: async () => 2n,
    ownerOf: async () => '0x' + '1'.repeat(40),
    isHealthy: async () => false,
    liquidate: async () => { throw Object.assign(Error('private data'), { code: 'BROADCAST_UNCERTAIN' }); },
  }, { dryRun: false, retries: 0, deadlineSeconds: 60 }, { log: s => logs.push(s) });
  assert.ok(logs.some(s => s.includes('BROADCAST_UNCERTAIN')));
  assert.ok(!logs.join().includes('private data'));
});
