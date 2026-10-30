// Ringer Vault's own redeem codes, as the extension checks them: the same
// rules as lib/subscription/redeem_code.dart in the app (FORMATS.md,
// section 10). A phone that redeemed a code writes it into the sync file;
// the extension checks the signature itself, with no server in between.
//
// A code is signed, not secret: anyone can read what it says, but only the
// holder of the private key can make one, or change what one says.

/**
 * The public half of the key the codes are signed with (raw Ed25519,
 * base64). Public by design: it can check a code, never make one. Made 30
 * October 2026 by tool/codes/make_codes.mjs.
 */
export const CODE_PUBLIC_KEY = 'qo65LFf0NHaNuPDZi36fsk/8GMuNMykinexT6Sf32+Y=';

/** What a code does. */
export const Kind = { days: 1, months: 2, lifetime: 3, cancel: 4 };

/** When a lifetime runs out: never, in practice. */
export const LIFETIME_UNTIL = Date.UTC(9999, 0, 1);

const CONTEXT = new TextEncoder().encode('ringer-vault-code');
const EPOCH_MS = Date.UTC(2020, 0, 1);
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * A code's contents, or null for anything that is not shaped like one.
 * Spaces and line breaks, as a pasted code may carry, are ignored. Says
 * nothing about whether it is genuine: see verifyCode.
 */
export function parseCode(text) {
  if (typeof text !== 'string') return null;
  const compact = text.replace(/\s+/g, '');
  if (!compact.startsWith('RV-')) return null;
  const encoded = compact.slice(3);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) return null;
  const bytes = fromBase64Url(encoded);
  if (bytes === null || bytes.length !== 78 || bytes[0] !== 1) return null;
  const kind = bytes[9];
  const amount = (bytes[10] << 8) | bytes[11];
  const timed = kind === Kind.days || kind === Kind.months;
  if (!Object.values(Kind).includes(kind) || (timed ? amount === 0 : amount !== 0)) return null;
  const redeemByDay = (bytes[12] << 8) | bytes[13];
  return {
    id: [...bytes.subarray(1, 9)].map((b) => b.toString(16).padStart(2, '0')).join(''),
    kind,
    amount,
    // Redeemable until the end of this day, UTC.
    redeemByMs: EPOCH_MS + (redeemByDay + 1) * DAY_MS,
    body: bytes.subarray(0, 14),
    signature: bytes.subarray(14),
  };
}

/** Whether [code] (from parseCode) was signed with [publicKey]. */
export async function verifyCode(code, { publicKey = CODE_PUBLIC_KEY, subtle = globalThis.crypto?.subtle } = {}) {
  if (!code || !subtle) return false;
  try {
    const key = await subtle.importKey('raw', fromBase64(publicKey), { name: 'Ed25519' }, false, ['verify']);
    const message = new Uint8Array(CONTEXT.length + code.body.length);
    message.set(CONTEXT);
    message.set(code.body, CONTEXT.length);
    return await subtle.verify({ name: 'Ed25519' }, key, code.signature, message);
  } catch {
    return false;
  }
}

/** [at] plus [count] calendar months, as Date (and Dart's DateTime) count them. */
function addMonths(at, count) {
  const date = new Date(at);
  date.setUTCMonth(date.getUTCMonth() + count);
  return date.getTime();
}

/** What a code gives, in a few words: "1 week", "1 month", "Lifetime". */
export function describeCode(code) {
  if (code.kind === Kind.days) return code.amount === 1 ? '1 day' : code.amount === 7 ? '1 week' : `${code.amount} days`;
  if (code.kind === Kind.months) {
    if (code.amount === 12) return '1 year';
    if (code.amount % 12 === 0) return `${code.amount / 12} years`;
    return code.amount === 1 ? '1 month' : `${code.amount} months`;
  }
  return code.kind === Kind.lifetime ? 'Lifetime' : 'Cancel';
}

/**
 * When Premium from the redeemed codes [grants] ({code, redeemedAt}) runs
 * out, in ms, or null when none counts. In the order they were redeemed: a
 * timed code starts when redeemed, or when the one before runs out if that
 * is later; a lifetime runs until LIFETIME_UNTIL; a cancel ends whatever is
 * running at that moment. Only genuine codes redeemed by their last day
 * count, each once, from its first use.
 */
export async function grantsUntil(grants, options = {}) {
  return (await grantsStatus(grants, options)).until;
}

/**
 * grantsUntil, and the plan of the latest code that gives Premium ("1 week",
 * "Lifetime"), or null: { until, plan }.
 */
export async function grantsStatus(grants, options = {}) {
  if (!Array.isArray(grants)) return { until: null, plan: null };
  // Checked before anything else, so nothing forged can stand in for a
  // genuine code, or push one out.
  const first = new Map();
  for (const grant of grants) {
    const code = parseCode(grant?.code);
    const redeemedAt = typeof grant?.redeemedAt === 'string' ? Date.parse(grant.redeemedAt) : NaN;
    if (code === null || !Number.isFinite(redeemedAt) || redeemedAt >= code.redeemByMs) continue;
    if (first.has(code.id) && first.get(code.id).redeemedAt <= redeemedAt) continue;
    if (!(await verifyCode(code, options))) continue;
    first.set(code.id, { code, redeemedAt });
  }
  const counted = [...first.values()].sort((a, b) => a.redeemedAt - b.redeemedAt);
  const giving = counted.filter(({ code }) => code.kind !== Kind.cancel);
  const plan = giving.length === 0 ? null : describeCode(giving[giving.length - 1].code);
  let until = null;
  for (const { code, redeemedAt } of counted) {
    const running = until !== null && until > redeemedAt;
    if (code.kind === Kind.cancel) {
      if (running) until = redeemedAt;
    } else if (code.kind === Kind.lifetime) {
      until = LIFETIME_UNTIL;
    } else if (!(running && until === LIFETIME_UNTIL)) {
      const start = running ? until : redeemedAt;
      until = code.kind === Kind.days ? start + code.amount * DAY_MS : addMonths(start, code.amount);
    }
  }
  return { until, plan };
}

function fromBase64(text) {
  const raw = atob(String(text));
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function fromBase64Url(text) {
  try {
    const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4);
    return fromBase64(padded);
  } catch {
    return null;
  }
}
