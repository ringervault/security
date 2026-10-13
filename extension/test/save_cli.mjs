// Saves a login into a sync file using the extension's own code.
//
//   node save_cli.mjs <password> <url> <username> <new password> < file
//
// Prints the new sealed file. Exists so the Dart suite can check that what
// the extension writes is a file the app reads and merges like its own.

import { openSealed, seal, entriesFrom } from '../src/vault/format.js';
import { applySave, planSave } from '../src/vault/save.js';

const [, , password, url, username, newPassword] = process.argv;

const text = await new Promise((resolve, reject) => {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { data += chunk; });
  process.stdin.on('end', () => resolve(data));
  process.stdin.on('error', reject);
});

try {
  const { parsed, key, params } = await openSealed(text, password);
  const login = { url, username, password: newPassword };
  const plan = planSave(entriesFrom(parsed), login);
  process.stdout.write(await seal(applySave(parsed, plan, login), key, params));
} catch (e) {
  process.stderr.write(String(e?.message ?? e));
  process.exit(1);
}
