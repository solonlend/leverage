import test from 'node:test';
import assert from 'node:assert/strict';
import { decideMove, withGasBuffer } from '../range-core.mjs';

const base = { lower: -198586, upper: -197586, lastAdj: 1_000n, now: 1_000 + 30 * 86400 };

test('in range: never moves, even when last adjustment is very old', () => {
  const d = decideMove({ ...base, tick: -198004 });
  assert.equal(d.inRange, true);
  assert.equal(d.needMove, false);
});

test('range boundaries count as in range', () => {
  assert.equal(decideMove({ ...base, tick: base.lower }).needMove, false);
  assert.equal(decideMove({ ...base, tick: base.upper }).needMove, false);
});

test('out of range on either side: moves', () => {
  assert.equal(decideMove({ ...base, tick: base.lower - 1 }).needMove, true);
  assert.equal(decideMove({ ...base, tick: base.upper + 1 }).needMove, true);
});

test('withGasBuffer adds 30% by default and rounds up', () => {
  assert.equal(withGasBuffer(988_326n), 1_284_824n);
  assert.equal(withGasBuffer(10n), 13n);
  assert.equal(withGasBuffer(1n), 2n);
});
