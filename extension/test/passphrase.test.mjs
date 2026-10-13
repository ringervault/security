import { test } from 'node:test';
import assert from 'node:assert/strict';

import { passphraseProblem } from '../src/vault/passphrase.js';

// The same answers as the app's validateUnlockSecret for a password, so a
// passphrase made in either place works in the other.
test('the app\'s passphrase rule', () => {
  assert.match(passphraseProblem('short'), /Add 7 more characters/);
  assert.match(passphraseProblem('a'.repeat(129)), /under 128/);
  assert.match(passphraseProblem(' correct horse battery'), /space/);
  assert.match(passphraseProblem('abababababab'), /variety/);
  assert.equal(passphraseProblem('glacier mosaic tundra velvet'), null);
  // Long enough, but the most famous passphrase there is: tried early.
  assert.match(passphraseProblem('correct horse battery staple'), /Too easy to guess/);
});
