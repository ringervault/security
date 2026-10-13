// The cases in test/fixtures/autofill_cases.json, which the app's Dart tests
// also run. Both passing means the app and the extension draw every site
// boundary the same way.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { registrableDomain, siteTier } from '../src/vault/host.js';

const cases = JSON.parse(
  readFileSync(new URL('../../test/fixtures/autofill_cases.json', import.meta.url)),
);

for (const c of cases.hosts) {
  test(`host: ${c.host}`, () => {
    const result = registrableDomain(c.host);
    if (c.rejection) {
      assert.equal(result.isUsable, false);
      assert.equal(result.rejection, c.rejection);
    } else {
      assert.equal(result.registrable, c.registrable);
      if (c.normalised) assert.equal(result.host, c.normalised);
    }
  });
}

for (const c of cases.tiers) {
  test(`tier: ${c.why}`, () => {
    assert.equal(siteTier(c.saved, c.page, c.scheme), c.tier);
  });
}
