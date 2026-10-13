// Creates a new, empty synced vault with the extension's own code, as a
// Google account with no vault gets when the extension is set up first.
// Prints the sealed file, for the Dart suite to open with the app's code.

import { newKey, seal, SYNC_FORMAT, SYNC_VERSION } from '../src/vault/format.js';

const [, , password] = process.argv;
const { key, params } = await newKey(password);
process.stdout.write(await seal({
  format: SYNC_FORMAT,
  version: SYNC_VERSION,
  writtenBy: 'chrome-extension',
  writtenAt: new Date().toISOString(),
  records: [],
}, key, params));
