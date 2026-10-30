// The redeem codes in test/fixtures/code_cases.json, which the app's Dart
// tests also run, plus how they count towards the plan.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';

import { CODE_PUBLIC_KEY, grantsStatus, grantsUntil, parseCode, verifyCode } from '../src/vault/codes.js';
import { subscriptionIn } from '../src/vault/plan.js';

globalThis.crypto ??= webcrypto;

const cases = JSON.parse(readFileSync(new URL('../../test/fixtures/code_cases.json', import.meta.url)));
const publicKey = cases.publicKey;

for (const c of cases.codes) {
  test(`code: ${c.why}`, async () => {
    const code = parseCode(c.code);
    const genuine = code !== null && await verifyCode(code, { publicKey });
    assert.equal(genuine, c.genuine);
    if (c.genuine) {
      assert.equal(code.id, c.id);
      assert.equal(code.kind, c.kind);
      assert.equal(code.amount, c.amount);
      assert.equal(new Date(code.redeemByMs - 1).toISOString().slice(0, 10), c.redeemBy);
    }
  });
}

for (const c of cases.grants) {
  test(`grants: ${c.why}`, async () => {
    const until = await grantsUntil(c.grants, { publicKey });
    assert.equal(until === null ? null : new Date(until).toISOString(), c.until);
  });
}

test('the real key does not accept codes made with the test key', async () => {
  assert.notEqual(CODE_PUBLIC_KEY, publicKey);
  assert.equal(await verifyCode(parseCode(cases.codes[0].code)), false);
});

test('a running code counts as subscribed, and lapses when it runs out', async () => {
  const file = { records: [], codeGrants: cases.grants[0].grants };
  const until = Date.parse(cases.grants[0].until);
  assert.deepEqual(await subscriptionIn(file, { now: until - 1000, codeKey: publicKey }),
    { subscribed: true, lapsed: false, codeUntil: until, viaPlay: false, codePlan: '1 day', codeEndedAt: null, playRenews: false });
  assert.deepEqual(await subscriptionIn(file, { now: until + 1000, codeKey: publicKey }),
    { subscribed: false, lapsed: true, codeUntil: null, viaPlay: false, codePlan: null, codeEndedAt: until, playRenews: false });
});

test('the plan named is the latest code giving Premium', async () => {
  const code = (why) => cases.codes.find((c) => c.why === why).code;
  const { plan } = await grantsStatus([
    { code: code('one day'), redeemedAt: '2026-11-01T00:00:00.000Z' },
    { code: code('lifetime'), redeemedAt: '2026-11-02T00:00:00.000Z' },
    { code: code('cancel'), redeemedAt: '2026-11-03T00:00:00.000Z' },
    { code: code('one month'), redeemedAt: '2026-11-04T00:00:00.000Z' },
  ], { publicKey });
  assert.equal(plan, '1 month');
});
