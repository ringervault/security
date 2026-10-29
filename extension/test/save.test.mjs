import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

import { applySave, planSave, SaveAction, siteTargetFor, titleFor } from '../src/vault/save.js';
import {
  openSealed, openWithKey, seal, BackupError, ITERATIONS_CURRENT, ITERATIONS_V1,
} from '../src/vault/format.js';

globalThis.crypto ??= webcrypto;

const entry = (over) => ({
  id: 'x', title: 'X', username: '', email: '', password: 'p', category: 'Social',
  notes: '', autofillTargets: [], ...over,
});

const amazon = entry({
  id: 'amazon', title: 'Amazon', email: 'ada@example.com', password: 'old',
  autofillTargets: ['site:amazon.in'],
});

test('a changed password for a saved account is an update', () => {
  const plan = planSave([amazon], {
    url: 'https://www.amazon.in/ap/signin', username: 'ADA@example.com', password: 'new',
  });
  assert.deepEqual(plan, { action: SaveAction.update, entryId: 'amazon', title: 'Amazon' });
});

test('the same password for a saved account needs nothing', () => {
  const plan = planSave([amazon], {
    url: 'https://www.amazon.in/', username: 'ada@example.com', password: 'old',
  });
  assert.equal(plan.action, SaveAction.none);
});

test('another account on the same site is a new entry', () => {
  const plan = planSave([amazon], {
    url: 'https://www.amazon.in/', username: 'grace@example.com', password: 'x',
  });
  assert.deepEqual(plan, { action: SaveAction.create, title: 'Amazon' });
});

test('an entry for a look-alike site is never updated', () => {
  const plan = planSave([amazon], {
    url: 'https://amazon-in.example/', username: 'ada@example.com', password: 'x',
  });
  assert.equal(plan.action, SaveAction.create);
});

test('no username and one entry for the site: that entry', () => {
  const plan = planSave([amazon], { url: 'https://www.amazon.in/', username: '', password: 'n' });
  assert.equal(plan.action, SaveAction.update);
});

test('titles and links', () => {
  assert.equal(titleFor('https://www.amazon.in/ap/signin'), 'Amazon');
  assert.equal(siteTargetFor('https://www.amazon.in/x'), 'site:amazon.in');
  assert.equal(siteTargetFor('https://accounts.google.com/'), 'site:accounts.google.com');
  // Never linked from a page anyone on the network could have changed.
  assert.equal(siteTargetFor('http://example.com/login'), null);
});

test('localhost is a site of its own, over http too', () => {
  const local = entry({ id: 'dev', title: 'Localhost', username: 'dev', password: 'old', autofillTargets: ['site:localhost'] });
  assert.equal(siteTargetFor('http://localhost:3000/login'), 'site:localhost');
  assert.equal(titleFor('http://localhost:3000/login'), 'Localhost');
  assert.deepEqual(
    planSave([], { url: 'http://localhost:3000/login', username: 'dev', password: 'x' }),
    { action: SaveAction.create, title: 'Localhost' },
  );
  // Its traffic never crosses the network, so a new password updates it.
  assert.equal(planSave([local], { url: 'http://localhost:8080/', username: 'dev', password: 'new' }).action, SaveAction.update);
  // A name that only starts like it is an ordinary http site.
  assert.equal(siteTargetFor('http://localhost.example.com/'), null);
});

const file = () => ({
  format: 'ringer-vault-sync',
  version: 1,
  writtenBy: 'phone',
  writtenAt: '2026-10-01T00:00:00.000Z',
  records: [
    {
      id: 'amazon',
      updatedAt: '2026-10-01T00:00:00.000Z',
      entry: {
        ...amazon,
        pin: '4321',
        extraPassword: 'transaction-password',
        extraPasswordLabel: 'Transaction',
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-10-01T00:00:00.000Z',
      },
    },
    { id: 'gone', updatedAt: '2026-09-01T00:00:00.000Z', deleted: true },
  ],
});

const now = new Date('2026-10-07T12:00:00.000Z');

test('an update keeps every field the extension does not show', () => {
  const next = applySave(
    file(),
    { action: SaveAction.update, entryId: 'amazon', title: 'Amazon' },
    { url: 'https://www.amazon.in/', username: 'ada@example.com', password: 'new' },
    { now },
  );
  const record = next.records.find((r) => r.id === 'amazon');
  assert.equal(record.updatedAt, now.toISOString());
  assert.equal(record.entry.password, 'new');
  assert.equal(record.entry.pin, '4321');
  assert.equal(record.entry.extraPassword, 'transaction-password');
  assert.equal(record.entry.createdAt, '2026-01-01T00:00:00.000Z');
  assert.equal(record.entry.updatedAt, now.toISOString());
  assert.deepEqual(record.entry.autofillTargets, ['site:amazon.in']);
  // Deletions are carried through, or a deleted password would come back.
  assert.ok(next.records.some((r) => r.id === 'gone' && r.deleted === true));
  assert.equal(next.writtenBy, 'chrome-extension');
});

test('a new login becomes a complete entry, linked to the exact address', () => {
  const next = applySave(
    file(),
    { action: SaveAction.create, title: 'Example' },
    { url: 'https://login.example.org/', username: 'grace', password: 'pw' },
    { now, newId: () => 'new-id' },
  );
  const record = next.records.find((r) => r.id === 'new-id');
  assert.deepEqual(record.entry.autofillTargets, ['site:login.example.org']);
  assert.equal(record.entry.username, 'grace');
  assert.equal(record.entry.email, '');
  for (const field of ['title', 'username', 'password', 'category', 'createdAt', 'updatedAt']) {
    assert.equal(typeof record.entry[field], 'string', field);
  }
});

test('an update to an entry deleted elsewhere saves a new one instead', () => {
  const next = applySave(
    file(),
    { action: SaveAction.update, entryId: 'gone', title: 'Gone' },
    { url: 'https://site.example/', username: 'a@b.c', password: 'pw' },
    { now, newId: () => 'fresh' },
  );
  assert.ok(next.records.some((r) => r.id === 'gone' && r.deleted === true));
  assert.equal(next.records.find((r) => r.id === 'fresh').entry.email, 'a@b.c');
});

test('a file from a newer app is refused, not rewritten', () => {
  assert.throws(() => applySave(
    { ...file(), version: 3 },
    { action: SaveAction.create, title: 'X' },
    { url: 'https://x.example/', username: 'a', password: 'b' },
  ));
});

test('sealing and opening again with the kept key, in both versions', async () => {
  const password = 'correct horse battery staple';
  for (const version of [1, 2]) {
    const salt = webcrypto.getRandomValues(new Uint8Array(16));
    const iterations = version === 1 ? ITERATIONS_V1 : ITERATIONS_CURRENT;
    // Make a file with known parameters by sealing with a key derived from them.
    const material = await webcrypto.subtle.importKey(
      'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey'],
    );
    const key = await webcrypto.subtle.deriveKey(
      { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
      material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'],
    );
    const params = { version, iterations, salt };
    const sealed = await seal(file(), key, params);

    const opened = await openSealed(sealed, password);
    assert.deepEqual(opened.parsed, file());
    assert.equal(opened.params.version, version);
    assert.equal(opened.params.iterations, iterations);
    assert.deepEqual(await openWithKey(sealed, opened.key, opened.params), file());

    // A file sealed under another salt, or upgraded, needs the passphrase again.
    const other = { ...params, salt: webcrypto.getRandomValues(new Uint8Array(16)) };
    await assert.rejects(openWithKey(sealed, opened.key, other), BackupError);
    const upgraded = { ...params, version: 2, iterations: ITERATIONS_CURRENT + 1 };
    await assert.rejects(openWithKey(sealed, opened.key, upgraded), BackupError);
  }
});

test('a browser whose clock runs behind still outranks what it has seen', async () => {
  const { nextStamp, applySave, planSave } = await import('../src/vault/save.js');
  const ahead = '2030-01-01T00:00:00.000Z';
  const records = [{ id: 'x', updatedAt: ahead, entry: { id: 'x', title: 'X', password: 'p' } }];
  assert.equal(nextStamp(records, new Date('2026-10-07T00:00:00Z')), '2030-01-01T00:00:00.001Z');
  assert.equal(nextStamp([], new Date('2026-10-07T00:00:00Z')), '2026-10-07T00:00:00.000Z');
  // The same millisecond is not enough: strictly after.
  assert.equal(nextStamp([{ updatedAt: '2026-10-07T00:00:00.000Z' }], new Date('2026-10-07T00:00:00Z')), '2026-10-07T00:00:00.001Z');

  const file = { format: 'ringer-vault-sync', version: 1, records };
  const login = { url: 'https://example.com/', username: 'me', password: 'new' };
  const saved = applySave(file, planSave([], login), login, { now: new Date('2026-10-07T00:00:00Z'), newId: () => 'n' });
  const added = saved.records.find((r) => r.id === 'n');
  assert.ok(added.updatedAt > ahead);
});

test('logins for the username already entered come first', async () => {
  const { splitByTypedUser } = await import('../src/vault/save.js');
  const c = (id, username, email = '') => ({ entry: { id, username, email } });
  const all = [c('a', 'ada'), c('b', '', 'Ada@Example.com'), c('c', 'bob'), c('d', '', '')];

  const byEmail = splitByTypedUser(all, ' ada@example.com ');
  assert.deepEqual(byEmail.mine.map((x) => x.entry.id), ['b']);
  assert.deepEqual(byEmail.others.map((x) => x.entry.id), ['a', 'c', 'd']);

  assert.deepEqual(splitByTypedUser(all, 'ADA').mine.map((x) => x.entry.id), ['a']);
  assert.deepEqual(splitByTypedUser(all, 'nobody').mine, []);
  // Nothing typed: nothing is "yours", everything is offered as before.
  assert.deepEqual(splitByTypedUser(all, '').others.length, 4);
  assert.deepEqual(splitByTypedUser(all, null).others.length, 4);
});

test('a sync file\'s generation is read, and missing means the oldest', async () => {
  const { generationOf } = await import('../src/vault/format.js');
  assert.equal(generationOf({ generation: 7 }), 7);
  assert.equal(generationOf({}), 0);
  assert.equal(generationOf({ generation: -1 }), 0);
  assert.equal(generationOf({ generation: '9' }), 0);
});

test('a page over plain http never replaces a saved password', () => {
  const entries = [{
    id: 'shop', title: 'Shop', username: 'ada', email: '', password: 'saved',
    autofillTargets: ['site:shop.example'],
  }];
  assert.equal(planSave(entries, { url: 'https://shop.example/login', username: 'ada', password: 'new' }).action, SaveAction.update);
  assert.equal(planSave(entries, { url: 'http://shop.example/login', username: 'ada', password: 'new' }).action, SaveAction.none);
  assert.equal(planSave(entries, { url: 'http://shop.example/login', username: 'someone-else', password: 'x' }).action, SaveAction.create,
    'a new login can still be saved, unlinked');
});
