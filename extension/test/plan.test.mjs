// The free plan and the subscription in the extension (src/vault/plan.js):
// the limit, and Google's signature on the record the phone writes.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  BELIEVED_MS, FREE_LOGINS, FreePlanFull, loginCount, PACKAGE_NAME, PRODUCT_ID, roomLeft, subscriptionIn, verifyPurchase,
} from '../src/vault/plan.js';

const { subtle } = globalThis.crypto;
const b64 = (buf) => Buffer.from(buf).toString('base64');

// Google Play's key pair, played by the test.
const pair = await subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-1' },
  true, ['sign', 'verify'],
);
const licenseKey = b64(await subtle.exportKey('spki', pair.publicKey));

async function signed(fields = {}) {
  const purchaseJson = JSON.stringify({
    orderId: 'GPA.1', packageName: PACKAGE_NAME, productId: PRODUCT_ID, purchaseState: 0, autoRenewing: true, ...fields,
  });
  const signature = b64(await subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(purchaseJson)));
  return { purchaseJson, signature };
}

const now = Date.parse('2026-11-01T09:00:00Z');
const fileWith = (record) => ({ records: [], entitlement: record });

test('the free plan holds 20, and room never goes below none', () => {
  assert.equal(FREE_LOGINS, 20);
  assert.equal(roomLeft(0, false), 20);
  assert.equal(roomLeft(18, false), 2);
  assert.equal(roomLeft(47, false), 0);
  assert.ok(roomLeft(47, true) > 1_000_000);
});

test('the refusal says how full it is and where to subscribe', () => {
  const full = new FreePlanFull({ count: 20, wanted: 1, room: 0 });
  assert.match(full.message, /holds 20 logins, and this vault has 20/);
  assert.match(full.message, /Android phone/);
  assert.match(new FreePlanFull({ count: 15, wanted: 9, room: 5 }).message, /add 9, and there is room for 5/);
});

test('Google\'s signature on this app\'s subscription checks out', async () => {
  const { purchaseJson, signature } = await signed();
  assert.equal(await verifyPurchase(purchaseJson, signature, { licenseKey }), true);
});

test('a changed record, another app or product, or a pending one is refused', async () => {
  const good = await signed();
  assert.equal(await verifyPurchase(good.purchaseJson.replace('GPA.1', 'GPA.2'), good.signature, { licenseKey }), false);
  for (const fields of [{ packageName: 'com.other' }, { productId: 'other' }, { purchaseState: 2 }]) {
    const r = await signed(fields);
    assert.equal(await verifyPurchase(r.purchaseJson, r.signature, { licenseKey }), false, JSON.stringify(fields));
  }
});

test('with no key set, nothing can be verified', async () => {
  const { purchaseJson, signature } = await signed();
  assert.equal(await verifyPurchase(purchaseJson, signature, { licenseKey: '' }), false);
});

test('subscribed within 35 days of the phone\'s last confirmation, lapsed after', async () => {
  const record = { ...(await signed()), confirmedAt: new Date(now).toISOString() };
  assert.deepEqual(await subscriptionIn(fileWith(record), { now: now + BELIEVED_MS - 1000, licenseKey }),
    { subscribed: true, lapsed: false });
  assert.deepEqual(await subscriptionIn(fileWith(record), { now: now + BELIEVED_MS + 1000, licenseKey }),
    { subscribed: false, lapsed: true });
});

test('a file without a record is the free plan', async () => {
  assert.deepEqual(await subscriptionIn({ records: [] }, { now, licenseKey }), { subscribed: false, lapsed: false });
});

test('deleted records do not count as logins', () => {
  assert.equal(loginCount({ records: [{ entry: {} }, { deleted: true }, { entry: {}, deleted: true }, { entry: {} }] }), 2);
});
