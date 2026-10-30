// The free plan and the subscription, as the extension sees them.
//
// Free: up to FREE_LOGINS logins in the vault. The subscription is bought in
// the Ringer Vault Android app through Google Play; the phone writes Google's
// signed record of it into the encrypted sync file (FORMATS.md), and this
// checks Google's signature on it with Play's public key for the app. Nothing
// is sold here, and no server of ours is asked.
//
// Free days from one of Ringer Vault's own redeem codes count too: the
// phone writes the codes it redeemed into the sync file (vault/codes.js).
//
// When a subscription ends, nothing saved is held back: every login can
// still be filled, edited and deleted. Only adding more waits for room, or
// for a subscription.

import { CODE_PUBLIC_KEY, grantsStatus } from './codes.js';

/** Logins a vault holds without a subscription (lib/subscription/plan.dart). */
export const FREE_LOGINS = 20;

/** The subscription's id in Play Console, and the app it belongs to. */
export const PRODUCT_ID = 'ringervault_premium';
export const PACKAGE_NAME = 'ringervault.password.manager';

/** How long the phone's last confirmation is believed (entitlement.dart). */
export const BELIEVED_MS = 35 * 24 * 60 * 60 * 1000;

/**
 * Google Play's public key for this app (Play Console, Monetization setup,
 * Licensing), base64 DER, copied 25 October 2026. Public by design: it can
 * only check Google's signatures, never make one. With none set, no
 * subscription could be verified and every vault would be on the free plan.
 */
export const PLAY_LICENSE_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1MkxpRz0nsa+TGlcKfCo6Sv5TBc7VZwLriHjAv/S2DvmdOI7KXVOPtbdgjr2WOxzV0q4//HESsok1NaJsBEtLT/q5u3c/DfzoNKZqBv93vTUuWHYJ0uzCS7aBc0JSNiKiZXWoQaH//moC+NZME7FzlwYUVeJnq9qwIhqaqzVrjk5cqPNk8Rt5TtfCyoOj2BU/oMz2+OOI6DVYYmJi/FqQBuMOoUe5Z7Swh7BikkmkjAD7q1tPuEiIw/z6uwh5CbukcPJZnqZ8vGrLsxu9BEBnk5I59pPBeRKHNcOYIakTJn4YPlEZkn9rXDJkE0tjcaLzQlk7ntMhudBlcHhU1qJewIDAQAB';

/** Room for new logins in a vault holding [count]. */
export function roomLeft(count, subscribed) {
  return subscribed ? Number.MAX_SAFE_INTEGER : Math.max(0, FREE_LOGINS - count);
}

/** Adding was refused: the free plan is full. Nothing was added. */
export class FreePlanFull extends Error {
  constructor({ count, wanted, room }) {
    super(room === 0
      ? `Your free plan holds ${FREE_LOGINS} logins, and this vault has ${count}. `
        + 'Subscribe in the Ringer Vault app on your Android phone to add more. '
        + 'Everything you have saved stays yours either way.'
      : `Your free plan holds ${FREE_LOGINS} logins. This would add ${wanted}, and `
        + `there is room for ${room}. Subscribe in the Ringer Vault app on your `
        + 'Android phone to add them all.');
    this.name = 'FreePlanFull';
    this.count = count;
    this.wanted = wanted;
    this.room = room;
  }
}

/**
 * What the decrypted sync file [parsed] says about the subscription:
 * { subscribed, lapsed, codeUntil, viaPlay, codePlan, codeEndedAt, playRenews }. Subscribed through Google Play only with
 * Google's signature checked, this app's product, and a confirmation the
 * phone made within BELIEVED_MS; or through redeem codes still running
 * (codeUntil, in ms, null when none). Lapsed: a record of either is there,
 * but neither counts now.
 */
export async function subscriptionIn(parsed, {
  now = Date.now(), licenseKey = PLAY_LICENSE_KEY, subtle = globalThis.crypto?.subtle,
  codeKey = CODE_PUBLIC_KEY,
} = {}) {
  const record = parsed?.entitlement;
  let play = false;
  if (record && typeof record === 'object') {
    const confirmedAt = Date.parse(record.confirmedAt ?? '');
    const genuine = await verifyPurchase(record.purchaseJson, record.signature, { licenseKey, subtle });
    play = genuine && Number.isFinite(confirmedAt) && now < confirmedAt + BELIEVED_MS;
  }
  const { until, plan } = await grantsStatus(parsed?.codeGrants, { publicKey: codeKey, subtle });
  const byCode = until !== null && now < until;
  const hadAny = (record && typeof record === 'object') || until !== null;
  return {
    subscribed: play || byCode,
    lapsed: Boolean(hadAny) && !(play || byCode),
    codeUntil: byCode ? until : null,
    viaPlay: play,
    // For saying the plan and its date: which code, when one ended, and
    // whether Google Play's renews (Play tells the phone no dates).
    codePlan: byCode ? plan : null,
    codeEndedAt: until !== null && !byCode ? until : null,
    playRenews: play && renews(record),
  };
}

/**
 * Whether [purchaseJson] is Google Play's own record of this app's
 * subscription: its RSA signature checks out with [licenseKey], and it names
 * this product and package as purchased.
 */
export async function verifyPurchase(purchaseJson, signature, { licenseKey = PLAY_LICENSE_KEY, subtle = globalThis.crypto?.subtle } = {}) {
  if (typeof purchaseJson !== 'string' || typeof signature !== 'string' || !licenseKey || !subtle) return false;
  let purchase;
  try {
    purchase = JSON.parse(purchaseJson);
  } catch {
    return false;
  }
  if (purchase?.packageName !== PACKAGE_NAME) return false;
  const products = Array.isArray(purchase.productIds) ? purchase.productIds : [purchase.productId];
  if (!products.includes(PRODUCT_ID)) return false;
  // 0 is "purchased"; 1 cancelled before completion, 2 pending.
  if (purchase.purchaseState !== undefined && purchase.purchaseState !== 0) return false;
  try {
    const key = await subtle.importKey(
      'spki', fromBase64(licenseKey), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-1' }, false, ['verify'],
    );
    return await subtle.verify('RSASSA-PKCS1-v1_5', key, fromBase64(signature), new TextEncoder().encode(purchaseJson));
  } catch {
    return false;
  }
}

/** Whether a Play record says it renews: the phone's word, else Google's. */
function renews(record) {
  if (typeof record.autoRenewing === 'boolean') return record.autoRenewing;
  try {
    return JSON.parse(record.purchaseJson).autoRenewing === true;
  } catch {
    return false;
  }
}

/** Logins (not deletions) in a decrypted sync file. */
export function loginCount(parsed) {
  return (parsed?.records ?? []).filter((r) => r && r.deleted !== true && r.entry).length;
}

function fromBase64(text) {
  const raw = atob(String(text).replace(/\s+/g, ''));
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
