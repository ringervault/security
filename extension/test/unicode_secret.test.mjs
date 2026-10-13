// A passphrase with letters that can be typed composed ("é", one character)
// or decomposed ("e" and an accent) makes the same key either way: new
// files use the composed form, and opening tries it before the text as
// typed, so files sealed before this still open. The app does the same.

import test from 'node:test';
import assert from 'node:assert/strict';
import { newKey, openSealed, seal, secretForms } from '../src/vault/format.js';

const composed = 'café déjà vu crème brûlée';
const decomposed = composed.normalize('NFD');

test('the two forms differ as text', () => {
  assert.notEqual(composed, decomposed);
  assert.deepEqual(secretForms(decomposed), [composed, decomposed]);
  assert.deepEqual(secretForms('plain ascii'), ['plain ascii']);
});

test('a file sealed now opens with the passphrase typed either way', async () => {
  const { key, params } = await newKey(decomposed);
  const file = await seal({ hello: 1 }, key, params);
  assert.deepEqual((await openSealed(file, composed)).parsed, { hello: 1 });
  assert.deepEqual((await openSealed(file, decomposed)).parsed, { hello: 1 });
});

test('a wrong passphrase still fails', async () => {
  const { key, params } = await newKey(composed);
  const file = await seal({ hello: 1 }, key, params);
  await assert.rejects(openSealed(file, 'cafe deja vu creme brulee'));
});

test('a file sealed before this, from the decomposed text as typed, still opens', async () => {
  const { deriveKey } = await import('../src/vault/format.js');
  const { params } = await newKey('x');
  const key = await deriveKey(decomposed, params);
  const file = await seal({ old: true }, key, params);
  assert.deepEqual((await openSealed(file, decomposed)).parsed, { old: true });
});
