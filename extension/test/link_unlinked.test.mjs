import { test } from 'node:test';
import assert from 'node:assert/strict';

import { candidatesFor, suggestedFor } from '../src/vault/match.js';
import { applyLink } from '../src/vault/save.js';

const entry = (over) => ({
  id: 'x', title: 'X', username: '', email: '', password: 'p', category: 'Social',
  notes: '', autofillTargets: [], ...over,
});

const linked = entry({ id: 'linked', title: 'Amazon', email: 'test@test.com', autofillTargets: ['site:amazon.in'] });
const unlinked = entry({ id: 'manual', title: 'Amazon', email: 'ada@example.com' });
const byUser = entry({ id: 'byuser', title: 'Shopping', username: 'amazon-ada' });
const bank = entry({ id: 'bank', title: 'HDFC Bank', autofillTargets: ['site:hdfcbank.com'] });
const notes = entry({ id: 'notes', title: 'Wi-Fi at home' });
const vault = [linked, unlinked, byUser, bank, notes];

const suggested = (url) =>
  suggestedFor(candidatesFor(vault, url).others, url).map((c) => c.entry.id);

test('an entry added by hand, with no website, is suggested on its site', () => {
  assert.deepEqual(suggested('https://www.amazon.in/ap/signin'), ['manual', 'byuser']);
});

test('the entry already linked is not suggested twice', () => {
  assert.ok(!suggested('https://www.amazon.in/').includes('linked'));
});

test('nothing named for another site is suggested', () => {
  assert.deepEqual(suggested('https://www.flipkart.com/'), []);
});

test('a very short site name suggests nothing', () => {
  assert.deepEqual(suggestedFor(candidatesFor(vault, 'https://x.co/').others, 'https://x.co/'), []);
});

test('an address that cannot be matched suggests nothing', () => {
  assert.deepEqual(suggestedFor(vault.map((e) => ({ entry: e })), 'https://192.168.1.1/'), []);
});

const file = () => ({
  format: 'ringer-vault-sync',
  version: 1,
  writtenBy: 'phone',
  writtenAt: '2026-10-01T00:00:00.000Z',
  records: [
    { id: 'manual', updatedAt: '2026-10-01T00:00:00.000Z', entry: { ...unlinked, pin: '4321', updatedAt: '2026-10-01T00:00:00.000Z' } },
    { id: 'gone', updatedAt: '2026-09-01T00:00:00.000Z', deleted: true },
  ],
});
const now = new Date('2026-10-08T12:00:00.000Z');

test('filling an unlinked entry links it to the site, and keeps everything else', () => {
  const next = applyLink(file(), 'manual', 'https://www.amazon.in/ap/signin', { now });
  const record = next.records.find((r) => r.id === 'manual');
  assert.deepEqual(record.entry.autofillTargets, ['site:amazon.in']);
  assert.equal(record.entry.pin, '4321');
  assert.equal(record.entry.password, 'p');
  assert.equal(record.updatedAt, now.toISOString());
  assert.equal(record.entry.updatedAt, now.toISOString());
  assert.equal(next.writtenBy, 'chrome-extension');
  assert.ok(next.records.some((r) => r.id === 'gone' && r.deleted), 'deletions kept');
});

test('nothing to change: already linked, deleted, or a plain http page', () => {
  const once = applyLink(file(), 'manual', 'https://www.amazon.in/', { now });
  assert.equal(applyLink(once, 'manual', 'https://www.amazon.in/', { now }), null);
  assert.equal(applyLink(file(), 'gone', 'https://www.amazon.in/', { now }), null);
  assert.equal(applyLink(file(), 'missing', 'https://www.amazon.in/', { now }), null);
  assert.equal(applyLink(file(), 'manual', 'http://www.amazon.in/', { now }), null);
});

test('refuses anything but the sync file', () => {
  assert.throws(() => applyLink({ records: [] }, 'manual', 'https://www.amazon.in/'));
  assert.throws(() => applyLink({ ...file(), version: 99 }, 'manual', 'https://www.amazon.in/'));
});
