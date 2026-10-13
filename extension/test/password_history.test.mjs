import { test } from 'node:test';
import assert from 'node:assert/strict';

import { applySave, SaveAction, withPreviousPassword, PASSWORD_HISTORY_LENGTH } from '../src/vault/save.js';
import { entriesFrom } from '../src/vault/format.js';

const file = (entry) => ({
  format: 'ringer-vault-sync',
  version: 2,
  generation: 3,
  writtenBy: 'phone',
  writtenAt: '2026-10-01T00:00:00.000Z',
  records: [{ id: 'amazon', updatedAt: '2026-10-01T00:00:00.000Z', entry: {
    id: 'amazon', title: 'Amazon', username: 'ada', email: '', password: 'old', category: 'Social',
    autofillTargets: ['site:amazon.in'], createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-10-01T00:00:00.000Z',
    ...entry,
  } }],
});
const update = (parsed, password, now) => applySave(
  parsed,
  { action: SaveAction.update, entryId: 'amazon', title: 'Amazon' },
  { url: 'https://www.amazon.in/', username: 'ada', password },
  { now },
);

test('an update keeps the password it replaces', () => {
  const next = update(file({}), 'new', new Date('2026-10-08T12:00:00.000Z'));
  const entry = next.records[0].entry;
  assert.equal(entry.password, 'new');
  assert.deepEqual(entry.passwordHistory, [{ password: 'old', replacedAt: '2026-10-08T12:00:00.000Z' }]);
});

test('newest first, five at most, no repeats', () => {
  let parsed = file({});
  for (let i = 1; i <= 7; i++) {
    parsed = update(parsed, `p${i}`, new Date(Date.UTC(2026, 9, 8, 12, i)));
  }
  const history = parsed.records[0].entry.passwordHistory.map((p) => p.password);
  assert.equal(history.length, PASSWORD_HISTORY_LENGTH);
  assert.deepEqual(history, ['p6', 'p5', 'p4', 'p3', 'p2']);
  parsed = update(parsed, 'p4', new Date(Date.UTC(2026, 9, 9)));
  // Going back to p4: it is current again, so no longer "previous".
  assert.deepEqual(parsed.records[0].entry.passwordHistory.map((p) => p.password), ['p7', 'p6', 'p5', 'p3', 'p2']);
});

test('a new entry starts with none', () => {
  const next = applySave(file({}), { action: SaveAction.create, title: 'Shop' },
    { url: 'https://shop.example/', username: 'ada', password: 'pw' }, { now: new Date(), newId: () => 'shop' });
  assert.equal(next.records.find((r) => r.id === 'shop').entry.passwordHistory, undefined);
});

test('never in the copy used for filling', () => {
  const next = update(file({}), 'new', new Date());
  const [forFilling] = entriesFrom(next);
  assert.equal(forFilling.passwordHistory, undefined);
  assert.equal(forFilling.password, 'new');
});

test('junk in a history is dropped, not fatal', () => {
  assert.deepEqual(
    withPreviousPassword([null, { password: '' }, { password: 7 }, { password: 'a', replacedAt: 'x' }], 'b', 'now'),
    [{ password: 'b', replacedAt: 'now' }, { password: 'a', replacedAt: 'x' }],
  );
  assert.deepEqual(withPreviousPassword('not a list', 'b', 'now'), [{ password: 'b', replacedAt: 'now' }]);
});
