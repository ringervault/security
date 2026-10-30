// Makes Ringer Vault's own redeem codes: free days of Premium, given away.
// Never sell them, or give them for payment outside Google Play: anything
// paid goes through Google Play's billing.
//
//   node tool/codes/make_codes.mjs --new-key
//       Makes the signing key, once, in secrets/code-signing-key.pem (kept
//       out of git), and prints the public key for CODE_PUBLIC_KEY in
//       lib/subscription/redeem_code.dart and extension/src/vault/codes.js.
//
//   node tool/codes/make_codes.mjs --plan week --redeem-by 2026-12-31 [--count 5]
//       Prints codes, one per line. --plan is one of:
//         day       1 day of Premium from the moment it is redeemed
//         week      7 days
//         month     1 calendar month
//         year      12 calendar months
//         lifetime  Premium for good
//         cancel    stops Premium from codes, there and then
//       A code redeemed while another runs adds on after it. Each can be
//       redeemed until the end of the --redeem-by day (UTC), once per phone.
//
// The format is in docs/FORMATS.md, section 10. The private key never leaves
// this computer: anyone holding it can make codes. Back it up somewhere
// safe; without it, new codes need a new key and an app and extension update.

import { createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { chmodSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const DEFAULT_KEY = join(ROOT, 'secrets', 'code-signing-key.pem');

/** Signed with this in front, so a code's signature means nothing elsewhere. */
export const CONTEXT = 'ringer-vault-code';
/** Day 0 of redeem-by dates. */
export const EPOCH_MS = Date.UTC(2020, 0, 1);
const DAY_MS = 24 * 60 * 60 * 1000;

/** What a code does: its type byte, and how many of it. */
export const PLANS = {
  day: { kind: 1, amount: 1 },
  week: { kind: 1, amount: 7 },
  month: { kind: 2, amount: 1 },
  year: { kind: 2, amount: 12 },
  lifetime: { kind: 3, amount: 0 },
  cancel: { kind: 4, amount: 0 },
};

/**
 * The 14 bytes a code signs: version 1, id, type (1 days, 2 calendar
 * months, 3 lifetime, 4 cancel), amount, last day to redeem.
 */
export function codeBody({ id, kind, amount, redeemByDay }) {
  if (!(id instanceof Uint8Array) || id.length !== 8) throw new Error('id must be 8 bytes');
  if (![1, 2, 3, 4].includes(kind)) throw new Error('unknown kind');
  const timed = kind === 1 || kind === 2;
  if (!Number.isInteger(amount) || (timed ? amount < 1 || amount > 0xffff : amount !== 0)) throw new Error('bad amount');
  if (!Number.isInteger(redeemByDay) || redeemByDay < 0 || redeemByDay > 0xffff) throw new Error('redeem-by date out of range');
  const body = new Uint8Array(14);
  body[0] = 1;
  body.set(id, 1);
  body[9] = kind;
  body[10] = amount >> 8;
  body[11] = amount & 0xff;
  body[12] = redeemByDay >> 8;
  body[13] = redeemByDay & 0xff;
  return body;
}

/** A finished code: "RV-" and the body and its signature, base64url. */
export function makeCode(privateKey, { id = randomBytes(8), kind, amount, redeemByDay }) {
  const body = codeBody({ id: new Uint8Array(id), kind, amount, redeemByDay });
  const signature = sign(null, Buffer.concat([Buffer.from(CONTEXT), body]), privateKey);
  return `RV-${Buffer.concat([body, signature]).toString('base64url')}`;
}

/** The raw 32-byte public key, base64, for CODE_PUBLIC_KEY. */
export function publicKeyText(privateKey) {
  const jwk = createPublicKey(privateKey).export({ format: 'jwk' });
  return Buffer.from(jwk.x, 'base64url').toString('base64');
}

/** Days from 2020-01-01 to a "YYYY-MM-DD" date. */
export function dayOf(text) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text ?? '');
  if (!match) throw new Error('--redeem-by must be a date like 2026-12-31');
  const at = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return Math.round((at - EPOCH_MS) / DAY_MS);
}

function argument(name) {
  const i = process.argv.indexOf(name);
  return i === -1 ? null : process.argv[i + 1] ?? null;
}

function main() {
  const keyPath = resolve(argument('--key') ?? DEFAULT_KEY);
  if (process.argv.includes('--new-key')) {
    if (existsSync(keyPath)) throw new Error(`${keyPath} already exists; codes already made with it would stop working if it changed.`);
    const { privateKey } = generateKeyPairSync('ed25519');
    writeFileSync(keyPath, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
    chmodSync(keyPath, 0o600);
    console.log(`Signing key written to ${keyPath}. Back it up; never commit or share it.`);
    console.log(`Public key: ${publicKeyText(privateKey)}`);
    return;
  }
  const plan = PLANS[argument('--plan')];
  if (!plan) throw new Error(`--plan must be one of: ${Object.keys(PLANS).join(', ')}`);
  const redeemByDay = dayOf(argument('--redeem-by'));
  const count = Number(argument('--count') ?? 1);
  if (!Number.isInteger(count) || count < 1 || count > 1000) throw new Error('--count must be 1 to 1000');
  if (redeemByDay < Math.floor((Date.now() - EPOCH_MS) / DAY_MS)) throw new Error('--redeem-by is already past');
  const privateKey = createPrivateKey(readFileSync(keyPath));
  for (let i = 0; i < count; i++) console.log(makeCode(privateKey, { ...plan, redeemByDay }));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
