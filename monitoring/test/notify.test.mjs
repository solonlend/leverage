import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as notifier from '../notify.mjs';

test('notifier writes structured stdout and private log', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'monitor-notify-'));
  try {
    const lines = [];
    const logFile = join(dir, 'events.jsonl');
    const notify = notifier.createNotifier({ logFile, stdout: line => lines.push(line), now: () => 0 });
    assert.equal(await notify('warn', 'feed is stale'), true);
    assert.deepEqual(JSON.parse(lines[0]), { time: '1970-01-01T00:00:00.000Z', level: 'warn', msg: 'feed is stale' });
    assert.equal(await readFile(logFile, 'utf8'), lines[0]);
    assert.equal((await stat(logFile)).mode & 0o777, 0o600);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('Telegram adapter sends message with timeout signal', async () => {
  let sent;
  const notify = notifier.createNotifier({ token: 'mock-secret', chatId: '42', stdout: () => {}, fetchImpl: async (url, options) => {
    sent = { url, options }; return { ok: true, json: async () => ({ ok: true }) };
  } });
  assert.equal(await notify('critical', 'bad debt'), true);
  assert.equal(sent.url, 'https://api.telegram.org/botmock-secret/sendMessage');
  assert.deepEqual(JSON.parse(sent.options.body), { chat_id: '42', text: '[critical] bad debt' });
  assert.ok(sent.options.signal instanceof AbortSignal);
});

test('local failure still attempts Telegram; errors never expose secrets', async () => {
  const lines = []; let attempted = false;
  const notify = notifier.createNotifier({ logFile: '/does-not-exist/monitor.log', token: 'mock-secret', chatId: '42', stdout: line => lines.push(line), fetchImpl: async () => {
    attempted = true; throw new Error('mock-secret https://rpc.invalid/?key=private');
  } });
  assert.equal(await notify('warn', 'stale feed'), false);
  assert.equal(attempted, true);
  assert.ok(lines.some(line => line.includes('Telegram delivery failed')));
  assert.ok(lines.some(line => line.includes('Log write failed')));
  assert.ok(!lines.join('').includes('mock-secret'));
  assert.ok(!lines.join('').includes('rpc.invalid'));
});

test('alert cooldown boundary, immediate escalation, clear, failed delivery retry', async () => {
  let time = 0; const sent = []; let succeeds = true;
  const alert = notifier.createAlertGate({ cooldownMs: 100, now: () => time, notify: async (...args) => { sent.push(args); return succeeds; } });
  await alert('feed', 'warn', 'stale');
  time = 99; await alert('feed', 'warn', 'stale'); assert.equal(sent.length, 1);
  time = 100; await alert('feed', 'warn', 'stale'); assert.equal(sent.length, 2);
  time = 101; await alert('feed', 'critical', 'very stale'); assert.equal(sent.length, 3);
  await alert('feed', 'critical', 'very stale'); assert.equal(sent.length, 3);
  alert.clear('feed'); await alert('feed', 'warn', 'stale'); assert.equal(sent.length, 4);
  succeeds = false; await alert('other', 'warn', 'failure'); await alert('other', 'warn', 'retry'); assert.equal(sent.length, 6);
});

test('Telegram HTTP and API rejection returns false using only fixed diagnostics', async () => {
  for (const response of [{ ok: false }, { ok: true, json: async () => ({ ok: false, description: 'sensitive detail' }) }]) {
    const lines = [];
    const notify = notifier.createNotifier({ token: 'secret', chatId: '42', stdout: line => lines.push(line), fetchImpl: async () => response });
    assert.equal(await notify('info', 'test'), false);
    assert.equal(JSON.parse(lines[1]).msg, 'Telegram delivery failed');
    assert.ok(!lines.join('').includes('sensitive detail'));
  }
});

test('stdout failure does not prevent Telegram delivery', async () => {
  let attempted = false;
  const notify = notifier.createNotifier({ token: 'secret', chatId: '42', stdout: () => { throw new Error('private'); }, fetchImpl: async () => {
    attempted = true; return { ok: true, json: async () => ({ ok: true }) };
  } });
  assert.equal(await notify('info', 'test'), false);
  assert.equal(attempted, true);
});
