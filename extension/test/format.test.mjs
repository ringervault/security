// The format reader on its own, without the app: shapes it must accept and
// refuse. The cross-implementation tests live in the Dart suite, which hands
// real app-written files to this code.

import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { decryptBackup, BackupError } from '../src/vault/format.js';

// Encrypts exactly as the app does, to plant files of any shape.
async function seal(json, password) {
  const salt = webcrypto.getRandomValues(new Uint8Array(16));
  const nonce = webcrypto.getRandomValues(new Uint8Array(12));
  const material = await webcrypto.subtle.importKey(
    'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
  const key = await webcrypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: 100000, hash: 'SHA-256' },
    material, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const sealed = new Uint8Array(await webcrypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, tagLength: 128 }, key,
    new TextEncoder().encode(JSON.stringify(json))));
  const ct = sealed.slice(0, -16);
  const mac = sealed.slice(-16);
  const out = new Uint8Array([...salt, ...nonce, ...mac, ...ct]);
  return Buffer.from(out).toString('base64');
}

const pw = 'correct horse battery staple';

test('a sync file with only deletions opens as an empty vault', async () => {
  const file = await seal({
    format: 'ringer-vault-sync', version: 1,
    records: [{ id: 'x', updatedAt: '2026-01-01T00:00:00Z', deleted: true }],
  }, pw);
  assert.deepEqual(await decryptBackup(file, pw), []);
});

test('an object that is not a sync file is refused', async () => {
  const file = await seal({ hello: 'world' }, pw);
  await assert.rejects(decryptBackup(file, pw), BackupError);
});

test('a sync file with a missing record list is refused', async () => {
  const file = await seal({ format: 'ringer-vault-sync', version: 1 }, pw);
  await assert.rejects(decryptBackup(file, pw), BackupError);
});

test('an old backup missing newer fields still opens', async () => {
  // A backup from before autofill targets existed.
  const file = await seal([{ id: '1', title: 'Old', password: 'p' }], pw);
  const [entry] = await decryptBackup(file, pw);
  assert.equal(entry.title, 'Old');
  assert.deepEqual(entry.autofillTargets, []);
  assert.equal(entry.username, '');
});

test('junk records in a sync file are skipped, not trusted', async () => {
  const file = await seal({
    format: 'ringer-vault-sync', version: 1,
    records: [null, 'x', { id: 'ok', entry: { id: 'ok', title: 'Fine' } }],
  }, pw);
  const entries = await decryptBackup(file, pw);
  assert.deepEqual(entries.map((e) => e.id), ['ok']);
});

// Version 2: the iteration count is recorded and bound to the ciphertext.
// No longer written for new vaults (see format_v3.test.mjs), but still read.
import {
  deriveKey, seal as v2Seal, openSealed as v2Open, BackupError as V2Error,
} from '../src/vault/format.js';

async function v2Key(password) {
  const params = { version: 2, iterations: 600000, salt: crypto.getRandomValues(new Uint8Array(16)) };
  return { key: await deriveKey(password, params), params };
}

test('a version 2 file at 600,000 iterations still opens', async () => {
  const { key, params } = await v2Key('correct horse battery staple');
  assert.equal(params.version, 2);
  assert.equal(params.iterations, 600000);
  const text = await v2Seal({ hello: 'world' }, key, params);
  const bytes = Buffer.from(text, 'base64');
  assert.equal(bytes.subarray(0, 4).toString(), 'RVLT');
  assert.equal(bytes.readUInt32BE(6), 600000);
  const opened = await v2Open(text, 'correct horse battery staple');
  assert.deepEqual(opened.parsed, { hello: 'world' });
});

test('changing the recorded iteration count breaks the file, never weakens it', async () => {
  const { key, params } = await v2Key('correct horse battery staple');
  const bytes = Buffer.from(await v2Seal({ a: 1 }, key, params), 'base64');
  bytes.writeUInt32BE(100000, 6);
  await assert.rejects(v2Open(bytes.toString('base64'), 'correct horse battery staple'), V2Error);
});

test('an absurd iteration count is refused before any work', async () => {
  const { key, params } = await v2Key('correct horse battery staple');
  const bytes = Buffer.from(await v2Seal({ a: 1 }, key, params), 'base64');
  bytes.writeUInt32BE(4000000000, 6);
  await assert.rejects(v2Open(bytes.toString('base64'), 'x'), /not a Ringer Vault backup/);
});
