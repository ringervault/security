import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  bytesKey, fromBase64, openText, passphraseKey, pinKey, pinProblem, randomBytes,
  sealText, toBase64,
} from '../src/vault/quick.js';

test('a PIN is 4 to 12 digits, not one digit repeated', () => {
  assert.equal(pinProblem('2580'), null);
  assert.equal(pinProblem('123456789012'), null);
  assert.match(pinProblem('123'), /at least 4/);
  assert.match(pinProblem('1234567890123'), /at most 12/);
  assert.match(pinProblem('12a4'), /digits only/);
  assert.match(pinProblem('1111'), /repeat/);
  assert.match(pinProblem(''), /at least 4/);
});

test('base64 round trip', () => {
  const bytes = randomBytes(37);
  assert.deepEqual(fromBase64(toBase64(bytes)), bytes);
});

test('the right PIN gives the passphrase back, a wrong one gives null', async () => {
  const salt = randomBytes(16);
  const box = await sealText('correct horse battery', await pinKey('2580', salt));
  assert.equal(await openText(box, await pinKey('2580', salt)), 'correct horse battery');
  assert.equal(await openText(box, await pinKey('2581', salt)), null);
  assert.equal(await openText(box, await pinKey('2580', randomBytes(16))), null);
});

test('the PIN kept on disk opens only with the passphrase', async () => {
  const salt = randomBytes(16);
  const box = await sealText('2580', await passphraseKey('correct horse battery', salt));
  assert.equal(await openText(box, await passphraseKey('correct horse battery', salt)), '2580');
  assert.equal(await openText(box, await passphraseKey('correct horse batterz', salt)), null);
});

test('a PRF secret seals the passphrase; another secret cannot open it', async () => {
  const prf = randomBytes(32);
  const box = await sealText('ünïcode passphrase ✓', await bytesKey(prf));
  assert.equal(await openText(box, await bytesKey(prf)), 'ünïcode passphrase ✓');
  assert.equal(await openText(box, await bytesKey(randomBytes(32))), null);
});

test('every seal uses a fresh IV', async () => {
  const key = await bytesKey(randomBytes(32));
  const a = await sealText('same', key);
  const b = await sealText('same', key);
  assert.notEqual(a.iv, b.iv);
  assert.notEqual(a.data, b.data);
});

test('a damaged box opens to null rather than throwing', async () => {
  const key = await bytesKey(randomBytes(32));
  const box = await sealText('secret', key);
  const bytes = fromBase64(box.data);
  bytes[0] ^= 1;
  assert.equal(await openText({ ...box, data: toBase64(bytes) }, key), null);
});
