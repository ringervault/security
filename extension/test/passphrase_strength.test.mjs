// The sync passphrase's strength, against the cases the app's tests run too.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describeBits, estimateBits, passphraseProblem } from '../src/vault/passphrase.js';

const fixture = JSON.parse(readFileSync(new URL('../../test/fixtures/passphrase_cases.json', import.meta.url)));

for (const c of fixture.cases) {
  test(`strength: ${c.passphrase}`, () => {
    assert.equal(Math.round(estimateBits(c.passphrase) * 10) / 10, c.bits);
    assert.equal(passphraseProblem(c.passphrase) !== null, c.refused);
  });
}

test('a refusal says how strong it was', () => {
  assert.match(passphraseProblem('Password@12345'), /about 13 bits/);
  assert.match(describeBits(estimateBits('glacier mosaic tundra velvet')), /^Very strong/);
});
