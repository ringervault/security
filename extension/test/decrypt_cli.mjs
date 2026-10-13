// Decrypts a backup using the extension's own code and prints the entries.
//
// Exists so the Dart test suite can hand a file written by the app to the
// JavaScript that will actually read it, rather than to a second copy of the
// format written from the same assumptions.

import { decryptBackup } from '../src/vault/format.js';

const [, , password] = process.argv;

const base64 = await new Promise((resolve, reject) => {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { data += chunk; });
  process.stdin.on('end', () => resolve(data));
  process.stdin.on('error', reject);
});

try {
  process.stdout.write(JSON.stringify(await decryptBackup(base64, password)));
} catch (e) {
  process.stderr.write(String(e?.message ?? e));
  process.exit(1);
}
