// The extension's list of accounts the vault holds (src/vault/known.js):
// keyed tags of site and username, never a password, so a locked vault does
// not ask to save a login it already has.

import test from 'node:test';
import assert from 'node:assert/strict';
import { knownTag, knownTags } from '../src/vault/known.js';

const key = new Uint8Array(32).fill(7);
const entries = [
  { username: 'ada', email: '', password: 'p', autofillTargets: ['site:www.bank.example'] },
  { username: '', email: 'ada@mail.example', password: 'q', autofillTargets: ['site:shop.example', 'app:com.x:aa'] },
];

test('every site and username pair the vault holds has a tag', async () => {
  const tags = await knownTags(entries, key);
  assert.ok(tags.includes(await knownTag(key, 'bank.example', 'ada')));
  assert.ok(tags.includes(await knownTag(key, 'shop.example', 'ADA@mail.example')), 'case does not matter');
  assert.equal(tags.includes(await knownTag(key, 'bank.example', 'someone')), false);
  assert.equal(tags.includes(await knownTag(key, 'other.example', 'ada')), false);
});

test('a tag is 16 bytes and depends on the key', async () => {
  const tag = await knownTag(key, 'bank.example', 'ada');
  assert.notEqual(tag, await knownTag(new Uint8Array(32).fill(8), 'bank.example', 'ada'));
  assert.equal(Buffer.from(tag, 'base64').length, 16);
});
