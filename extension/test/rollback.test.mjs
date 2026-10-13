// The rollback rules, with storage faked, and the cases shared with the app.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { RolledBackError } from '../src/vault/format.js';
import { acceptCopy, adoptCopy, generationStep, nextCopy } from '../src/vault/rollback.js';

const fixture = JSON.parse(readFileSync(new URL('../../test/fixtures/rollback_cases.json', import.meta.url)));

/** chrome.storage stand-in: one number, and every write made to it. */
function fakeStore(start = 0) {
  const writes = [];
  let value = start;
  return { writes, get: async () => value, set: async (n) => { value = n; writes.push(n); } };
}

for (const c of fixture.cases) {
  test(`generation: ${c.why}`, async () => {
    assert.equal(generationStep(c), c.refuse ? null : c.next);

    if (c.acceptOlder) return;
    const store = fakeStore(c.seen);
    const parsed = { generation: c.found };
    if (c.refuse) {
      await assert.rejects(acceptCopy(parsed, store), RolledBackError);
      assert.deepEqual(store.writes, [], 'nothing remembered from a refused copy');
      return;
    }
    await acceptCopy(parsed, store);
    assert.equal(await store.get(), Math.max(c.seen, c.found));
    const next = await nextCopy({ records: [] }, parsed, store);
    assert.equal(next.generation, c.next);
    assert.equal(next.version, 2);
  });
}

test('connecting with the passphrase takes an older copy, and the next write is above all', async () => {
  const store = fakeStore(7);
  await adoptCopy({ generation: 2 }, store);
  assert.equal(await store.get(), 2);
  await acceptCopy({ generation: 2 }, store);
  assert.equal((await nextCopy({}, { generation: 2 }, store)).generation, 3);
});

test('a copy without a counter is generation 0', async () => {
  await assert.rejects(acceptCopy({}, fakeStore(1)), RolledBackError);
  await acceptCopy({}, fakeStore(0));
});
