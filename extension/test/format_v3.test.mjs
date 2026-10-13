// Version 3 sealed files (Argon2id), and the vendored hash-wasm build they
// rest on. test/fixtures/argon2id_vector.json is shared with the app.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  ARGON2_CURRENT, argon2Bytes, BackupError, newKey, openSealed, openWithKey, paramsOf, seal,
} from '../src/vault/format.js';

const vector = JSON.parse(readFileSync(new URL('../../test/fixtures/argon2id_vector.json', import.meta.url)));
const hex = (s) => Uint8Array.from(s.match(/../g).map((b) => parseInt(b, 16)));

test('the vendored Argon2id is the pinned hash-wasm 4.12.0 build', () => {
  // From the npm tarball whose sha512 matched the registry's integrity
  // field. A changed file has to be re-checked the same way, then pinned.
  const file = readFileSync(new URL('../src/vendor/hash-wasm-argon2-4.12.0.umd.min.js', import.meta.url));
  assert.equal(createHash('sha256').update(file).digest('hex'),
    'dcec617a2e1b700fa132d1583a186cb70611113395e869f2dd6cc82b415d3094');
});

test('Argon2id gives the bytes the app gives', async () => {
  const key = await argon2Bytes(vector.password, hex(vector.saltHex),
    { memoryKib: vector.memoryKib, passes: vector.passes, lanes: vector.lanes });
  assert.equal(Buffer.from(key).toString('hex'), vector.keyHex);
});

test('a file the app sealed opens here', async () => {
  const { parsed, params } = await openSealed(vector.sealedByApp, vector.password);
  assert.equal(parsed.format, 'ringer-vault-sync');
  assert.equal(params.version, 3);
});

test('a new vault is sealed as version 3 at the app\'s settings', async () => {
  const { key, params } = await newKey('a passphrase');
  assert.equal(params.version, 3);
  assert.deepEqual([params.memoryKib, params.iterations, params.lanes],
    [ARGON2_CURRENT.memoryKib, ARGON2_CURRENT.passes, ARGON2_CURRENT.lanes]);
  const text = await seal({ hello: 1 }, key, params);
  assert.equal(paramsOf(text).version, 3);
  assert.deepEqual(await openWithKey(text, key, params), { hello: 1 });
  assert.deepEqual((await openSealed(text, 'a passphrase')).parsed, { hello: 1 });
});

test('a changed header is caught', async () => {
  const bytes = Buffer.from(vector.sealedByExtension, 'base64');
  bytes[13] += 1; // one more pass
  await assert.rejects(openSealed(bytes.toString('base64'), vector.password), BackupError);
});

test('settings too weak or too costly are refused before any work', () => {
  for (const [m, t, p] of [[1024, 3, 1], [4 * 1024 * 1024, 3, 1], [1024 * 1024, 3, 1], [512 * 1024, 3, 1], [256 * 1024, 3, 1], [32768, 7, 1], [32768, 11, 1], [32768, 20, 1], [32768, 0, 1], [32768, 1000, 1], [32768, 3, 0], [32768, 3, 200]]) {
    const b = Buffer.from(vector.sealedByExtension, 'base64');
    b.writeUInt32BE(m, 6);
    b.writeUInt32BE(t, 10);
    b[14] = p;
    assert.throws(() => paramsOf(b.toString('base64')), BackupError, `${m} ${t} ${p}`);
  }
  // The most a file may ask for is still read.
  const most = Buffer.from(vector.sealedByExtension, 'base64');
  most.writeUInt32BE(128 * 1024, 6);
  most.writeUInt32BE(6, 10);
  most[14] = 1;
  assert.doesNotThrow(() => paramsOf(most.toString('base64')));
});

test('a later version says to update', () => {
  const b = Buffer.from(vector.sealedByExtension, 'base64');
  b[4] = 4;
  assert.throws(() => paramsOf(b.toString('base64')), /newer version/);
});
