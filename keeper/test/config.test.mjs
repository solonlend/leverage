import test from 'node:test';
import assert from 'node:assert/strict';
import { readConfig } from '../config.mjs';
const env = { RPC_URL: 'http://localhost:8545', VAULT_ADDRESS: '0x' + '1'.repeat(40) };
test('default is dry and never requires or exposes a private key', () => {
  assert.equal(readConfig(env).dryRun, true);
  assert.equal('privateKey' in readConfig({ ...env, KEEPER_PRIVATE_KEY: 'sensitive' }), false);
});
test('explicit live requires key and positive slippage protection', () => {
  assert.throws(() => readConfig({ ...env, DRY_RUN: 'false' }), /MIN_SEIZE_VALUE/);
  assert.throws(() => readConfig({ ...env, DRY_RUN: 'false', MIN_SEIZE_VALUE: '1' }), /KEEPER_PRIVATE_KEY/);
});
test('reject malformed config without repeating supplied values', () => {
  for (const [key, value] of Object.entries({ DRY_RUN: 'FALSE', RATIO_BPS: '10001', MIN_SEIZE_VALUE: '-1', POLL_INTERVAL_MS: '0', RPC_URL: 'secret', VAULT_ADDRESS: 'secret' })) {
    assert.throws(() => readConfig({ ...env, [key]: value }), error => !error.message.includes('secret'));
  }
});
