import test from 'node:test';
import assert from 'node:assert/strict';

const now = Date.parse('2026-09-06T12:00:00.000Z') / 1000;
const lineAt = (time, failed = 0) => `${new Date(time * 1000).toISOString()} heartbeat scanned=12 active=10 unhealthy=2 failed=${failed}`;

test('successful complete keeper heartbeat yields its original timestamp', async () => {
  const { parseHeartbeat } = await import('../heartbeat.mjs');
  assert.deepEqual(parseHeartbeat(lineAt(now), now), { updatedAt: now });
});

for (const [age, accepted] of [[0, true], [59.999, true], [60, true], [60.001, false], [-0.001, false]]) {
  test(`heartbeat age ${age}s acceptance is ${accepted}`, async () => {
    const { parseHeartbeat } = await import('../heartbeat.mjs');
    assert.equal(parseHeartbeat(lineAt(now - age), now) !== null, accepted);
  });
}

for (const [label, line] of [
  ['failed scan', lineAt(now, 1)],
  ['missing active', lineAt(now).replace('active=10 ', '')],
  ['missing failed', lineAt(now).replace(' failed=0', '')],
  ['untrusted suffix', `${lineAt(now)} secret=do-not-log`],
  ['untrusted prefix', `secret=do-not-log ${lineAt(now)}`],
  ['invalid timestamp', lineAt(now).replace('T12:', 'T99:')],
]) {
  test(`rejects ${label}`, async () => {
    const { parseHeartbeat } = await import('../heartbeat.mjs');
    assert.equal(parseHeartbeat(line, now), null);
  });
}

import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const script = fileURLToPath(new URL('../heartbeat.mjs', import.meta.url));

test('EOF revokes even successful final heartbeat without forwarding raw logs', async () => {
  const dir = await mkdtemp(fileURLToPath(new URL('../.heartbeat-test-', import.meta.url)));
  try {
    const file = join(dir, 'beat.json');
    const current = Math.floor(Date.now() / 1000);
    const result = spawnSync(process.execPath, [script], {
      env: { ...process.env, HEARTBEAT_FILE: file },
      input: `PRIVATE_KEY=never-echo\n${lineAt(current)}\n${lineAt(current, 1)}\n`, encoding: 'utf8',
    });
    assert.equal(result.status, 0);
    assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), { updatedAt: 0 });
    assert.deepEqual(await readdir(dir), ['beat.json']);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('file errors exit nonzero with fixed sanitized stderr', () => {
  const result = spawnSync(process.execPath, [script], {
    env: { ...process.env, HEARTBEAT_FILE: '/unavailable-do-not-log-secret/beat.json' },
    input: `${lineAt(Math.floor(Date.now() / 1000))}\n`, encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'Heartbeat sidecar failed; check HEARTBEAT_FILE and input.\n');
});

test('rejects calendar overflow instead of normalizing to a fresh timestamp', async () => {
  const { parseHeartbeat } = await import('../heartbeat.mjs');
  const impossible = '2026-02-30T12:00:00.000Z heartbeat scanned=12 active=10 unhealthy=2 failed=0';
  assert.equal(parseHeartbeat(impossible, Date.parse('2026-03-02T12:00:00.000Z') / 1000), null);
});

test('millisecond ISO timestamps produce integer Unix seconds', async () => {
  const { parseHeartbeat } = await import('../heartbeat.mjs');
  const result = parseHeartbeat(lineAt(now + 0.123), now + 0.5);
  assert.deepEqual(result, { updatedAt: now });
  assert.equal(Number.isSafeInteger(result.updatedAt), true);
});


test('CLI refuses an output path outside monitoring', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'monitor-heartbeat-'));
  try {
    const result = spawnSync(process.execPath, [script], {
      env: { ...process.env, HEARTBEAT_FILE: join(dir, 'beat.json') },
      input: `${lineAt(Math.floor(Date.now() / 1000))}\n`, encoding: 'utf8',
    });
    assert.equal(result.status, 1);
    assert.deepEqual(await readdir(dir), []);
    assert.equal(result.stdout, '');
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('exported atomic writer supports isolated temporary directory tests', async () => {
  const { writeHeartbeat } = await import('../heartbeat.mjs');
  const dir = await mkdtemp(join(tmpdir(), 'monitor-heartbeat-'));
  try {
    const file = join(dir, 'beat.json');
    await writeHeartbeat(file, { updatedAt: now });
    assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), { updatedAt: now });
    assert.deepEqual(await readdir(dir), ['beat.json']);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

import { spawn } from 'node:child_process';
import { once, EventEmitter } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { PassThrough } from 'node:stream';

async function waitForTimestamp(file, expected) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const value = await readFile(file, 'utf8').then(JSON.parse).catch(() => null);
    if (value?.updatedAt === expected) return;
    await delay(10);
  }
  assert.fail(`heartbeat did not become ${expected}`);
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  test(`live stream clears old heartbeat at startup, updates, then revokes on ${signal}`, async () => {
    const { writeHeartbeat } = await import('../heartbeat.mjs');
    const dir = await mkdtemp(fileURLToPath(new URL('../.heartbeat-test-', import.meta.url)));
    const file = join(dir, 'beat.json');
    await writeHeartbeat(file, { updatedAt: now });
    const child = spawn(process.execPath, [script], { env: { ...process.env, HEARTBEAT_FILE: file }, stdio: ['pipe', 'pipe', 'pipe'] });
    const exited = once(child, 'exit');
    try {
      await waitForTimestamp(file, 0);
      const current = Math.floor(Date.now() / 1000);
      child.stdin.write(`${lineAt(current)}\n`);
      await waitForTimestamp(file, current);
      child.kill(signal);
      await exited;
      await waitForTimestamp(file, 0);
    } finally {
      if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await exited; }
      await rm(dir, { recursive: true, force: true });
    }
  });
}

test('input error revokes the last successful heartbeat', async () => {
  const { runHeartbeatStream } = await import('../heartbeat.mjs');
  const input = new PassThrough();
  const signals = new EventEmitter();
  const records = [];
  const running = runHeartbeatStream(input, 'unused', { signals, write: async (_, value) => records.push(value.updatedAt) });
  const rejected = assert.rejects(running, /synthetic input failure/);
  input.write(`${lineAt(Math.floor(Date.now() / 1000))}\n`);
  await delay(10);
  input.destroy(new Error('synthetic input failure'));
  await rejected;
  assert.ok(records.some(value => value > 0));
  assert.equal(records.at(-1), 0);
});

test('signal waits for pending successful write before final revocation', async () => {
  const { runHeartbeatStream } = await import('../heartbeat.mjs');
  const input = new PassThrough();
  const signals = new EventEmitter();
  const records = [];
  let release;
  let started;
  const writing = new Promise(resolve => { started = resolve; });
  const running = runHeartbeatStream(input, 'unused', {
    signals,
    write: async (_, value) => {
      if (value.updatedAt > 0) {
        started();
        await new Promise(resolve => { release = resolve; });
      }
      records.push(value.updatedAt);
    },
  });
  input.write(`${lineAt(Math.floor(Date.now() / 1000))}\n`);
  await writing;
  signals.emit('SIGTERM');
  release();
  await running;
  assert.equal(records.at(-1), 0);
  assert.equal(records.filter(value => value > 0).length, 1);
});

test('a heartbeat write failure revokes any previous successful heartbeat', async () => {
  const { runHeartbeatStream } = await import('../heartbeat.mjs');
  const input = new PassThrough();
  const records = [];
  const running = runHeartbeatStream(input, 'unused', {
    signals: new EventEmitter(),
    write: async (_, value) => {
      if (value.updatedAt > 0) throw new Error('synthetic write failure');
      records.push(value.updatedAt);
    },
  });
  const rejected = assert.rejects(running, /synthetic write failure/);
  input.write(`${lineAt(Math.floor(Date.now() / 1000))}\n`);
  await rejected;
  assert.deepEqual(records, [0, 0]);
});
