// Reads, and for the Drive sync file writes, the encrypted vault.
//
// The file is the interchange contract between the app and this extension
// (lib/utils/sealed_file.dart is the app's side of it).
//
// Version 1, still read:
//   base64( salt(16) || nonce(12) || mac(16) || ciphertext )
//   key = PBKDF2-HMAC-SHA256(password, salt, 100000 iterations, 256 bits)
//
// Version 2, read, and written back to a file that is version 2:
//   base64( "RVLT" || 0x02 || kdf(0x01 = PBKDF2-SHA256) || iterations(u32 BE)
//           || salt(16) || nonce(12) || mac(16) || ciphertext )
//   the first 10 bytes are AES-GCM additional data, so they cannot be
//   altered unnoticed.
//
// Version 3, written for every new vault (and written back to a version 3
// file); an older file keeps the version and salt it was read with:
//   base64( "RVLT" || 0x03 || kdf(0x02 = Argon2id) || memory KiB(u32 BE)
//           || passes(u32 BE) || lanes(u8) || salt(16) || nonce(12)
//           || mac(16) || ciphertext )
//   the first 15 bytes are AES-GCM additional data.
//
// The file sits in Google Drive where a copy could be attacked offline, and
// PBKDF2 at any count is cheap on graphics cards; Argon2id needs memory for
// every guess. Browsers have no Argon2id, so it comes from hash-wasm, an
// audited WebAssembly build vendored in ../vendor at a pinned version whose
// SHA-256 a test checks. Nothing cryptographic is hand-written here: AES-GCM
// and PBKDF2 are WebCrypto's, and a test vector shared with the app's Dart
// Argon2id (test/fixtures/argon2id_vector.json) catches any drift.

import '../vendor/hash-wasm-argon2-4.12.0.umd.min.js';

const { argon2id } = globalThis.hashwasm;

const SALT_BYTES = 16;
const NONCE_BYTES = 12;
const MAC_BYTES = 16;
const MAGIC = [0x52, 0x56, 0x4c, 0x54]; // "RVLT"
const V2_HEADER_BYTES = 10;
const V3_HEADER_BYTES = 15;
const KDF_PBKDF2_SHA256 = 0x01;
const KDF_ARGON2ID = 0x02;

/** Argon2id for new files: the app's settings (lib/utils/sealed_file.dart). */
export const ARGON2_CURRENT = { memoryKib: 64 * 1024, passes: 3, lanes: 1 };
/**
 * Refused when reading, like MAX_ITERATIONS: a file is read before it can
 * be authenticated, so this is what a stranger's file could demand. The
 * same limits as the app (lib/utils/sealed_file.dart).
 */
const ARGON2_LIMITS = { minMemoryKib: 19 * 1024, maxMemoryKib: 128 * 1024, maxPasses: 6, maxLanes: 8 };

export const ITERATIONS_V1 = 100000;
export const ITERATIONS_CURRENT = 600000;
/** Refused when reading: a crafted file must not stall or weaken the key. */
const MAX_ITERATIONS = 10000000;

export class BackupError extends Error {}

function bytesToBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function base64ToBytes(base64) {
  const binary = atob(base64.trim());
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** The AES-GCM key [password] makes under [params], of any version. */
export async function deriveKey(password, params) {
  return (await deriveKeys(password, params)).key;
}

/**
 * The vault key [password] makes with [params], and from the same costly
 * derivation a second key for sealing the quick-unlock PIN (quick.js).
 * The PIN's sealed copy is kept on disk, so whatever seals it must cost a
 * guesser as much as the vault itself; a cheaper key there would be the
 * easier way to test passphrase guesses.
 */
export async function deriveKeys(password, params) {
  if (params.version === 3) {
    const raw = await argon2id({
      password: new TextEncoder().encode(password),
      salt: params.salt,
      parallelism: params.lanes,
      iterations: params.iterations,
      memorySize: params.memoryKib,
      hashLength: 32,
      outputType: 'binary',
    });
    try {
      return {
        // Not extractable, as below.
        key: await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt', 'encrypt']),
        pinBoxKey: await labelledKey(raw, PIN_BOX_LABEL),
      };
    } finally {
      raw.fill(0);
    }
  }
  // Older files: the PIN key from the same PBKDF2 run as the vault key.
  const material = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits'],
  );
  const raw = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: params.salt, iterations: params.iterations, hash: 'SHA-256' },
    material,
    256,
  ));
  try {
    return {
      // The same bits PBKDF2 gives an AES-256 key directly (pbkdf2Key).
      key: await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt', 'encrypt']),
      pinBoxKey: await labelledKey(raw, PIN_BOX_LABEL),
    };
  } finally {
    raw.fill(0);
  }
}

const PIN_BOX_LABEL = 'Ringer Vault PIN box v2';

/** An AES key from [raw] for one purpose, by HKDF-SHA256 with [label]. */
async function labelledKey(raw, label) {
  const material = await crypto.subtle.importKey('raw', raw, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: new TextEncoder().encode(label) },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

/** Argon2id's raw output, for the shared test vector. */
export const argon2Bytes = (password, salt, { memoryKib, passes, lanes }) => argon2id({
  password: new TextEncoder().encode(password),
  salt,
  parallelism: lanes,
  iterations: passes,
  memorySize: memoryKib,
  hashLength: 32,
  outputType: 'binary',
});

async function pbkdf2Key(password, salt, iterations) {
  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password),
    'PBKDF2',
    false,
    ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    // Not extractable: the key can be used while the vault is unlocked, and
    // never read out, logged or stored.
    false,
    ['decrypt', 'encrypt'],
  );
}

function header(params) {
  if (params.version === 3) {
    const out = new Uint8Array(V3_HEADER_BYTES);
    out.set(MAGIC, 0);
    out[4] = 0x03;
    out[5] = KDF_ARGON2ID;
    const view = new DataView(out.buffer);
    view.setUint32(6, params.memoryKib);
    view.setUint32(10, params.iterations);
    out[14] = params.lanes;
    return out;
  }
  const out = new Uint8Array(V2_HEADER_BYTES);
  out.set(MAGIC, 0);
  out[4] = 0x02;
  out[5] = KDF_PBKDF2_SHA256;
  new DataView(out.buffer).setUint32(6, params.iterations);
  return out;
}

/** The version a file declares: its byte after "RVLT", or 1 without it. */
const versionOf = (b) => (b.length > V2_HEADER_BYTES
  && b[0] === MAGIC[0] && b[1] === MAGIC[1] && b[2] === MAGIC[2] && b[3] === MAGIC[3]
  ? b[4] : 1);

/** The parts of a sealed file of either version, or a BackupError. */
function split(base64Text) {
  let bytes;
  try {
    bytes = base64ToBytes(base64Text);
  } catch {
    throw new BackupError('This file is not a Ringer Vault backup.');
  }

  let at = 0;
  let params = { version: 1, iterations: ITERATIONS_V1, memoryKib: 0, lanes: 0 };
  let aad = new Uint8Array(0);
  const newer = () => new BackupError('This file was made by a newer version of Ringer Vault. Update the extension.');
  const notOurs = () => new BackupError('This file is not a Ringer Vault backup.');
  const u32 = (from) => new DataView(bytes.buffer, bytes.byteOffset + from, 4).getUint32(0);
  const version = versionOf(bytes);
  if (version === 2) {
    if (bytes[5] !== KDF_PBKDF2_SHA256) throw newer();
    const iterations = u32(6);
    if (iterations < ITERATIONS_V1 || iterations > MAX_ITERATIONS) throw notOurs();
    params = { version: 2, iterations, memoryKib: 0, lanes: 0 };
    aad = bytes.slice(0, V2_HEADER_BYTES);
    at = V2_HEADER_BYTES;
  } else if (version === 3) {
    if (bytes.length <= V3_HEADER_BYTES) throw notOurs();
    if (bytes[5] !== KDF_ARGON2ID) throw newer();
    const memoryKib = u32(6);
    const iterations = u32(10);
    const lanes = bytes[14];
    const L = ARGON2_LIMITS;
    if (memoryKib < L.minMemoryKib || memoryKib > L.maxMemoryKib || iterations < 1
      || iterations > L.maxPasses || lanes < 1 || lanes > L.maxLanes || memoryKib < 8 * lanes) {
      throw notOurs();
    }
    params = { version: 3, iterations, memoryKib, lanes };
    aad = bytes.slice(0, V3_HEADER_BYTES);
    at = V3_HEADER_BYTES;
  } else if (version !== 1) {
    throw newer();
  }

  if (bytes.length <= at + SALT_BYTES + NONCE_BYTES + MAC_BYTES) {
    throw new BackupError('This file is not a Ringer Vault backup.');
  }

  const salt = bytes.slice(at, at + SALT_BYTES);
  at += SALT_BYTES;
  const nonce = bytes.slice(at, at + NONCE_BYTES);
  at += NONCE_BYTES;
  const mac = bytes.slice(at, at + MAC_BYTES);
  at += MAC_BYTES;
  const ciphertext = bytes.slice(at);

  // The Dart side stores the GCM tag in its own field; WebCrypto expects it
  // appended to the ciphertext. Reassembling it is the whole adaptation.
  const sealed = new Uint8Array(ciphertext.length + mac.length);
  sealed.set(ciphertext, 0);
  sealed.set(mac, ciphertext.length);
  return { params: { ...params, salt }, nonce, sealed, aad };
}

async function decryptParts({ nonce, sealed, aad }, key) {
  let plain;
  try {
    plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce, tagLength: MAC_BYTES * 8, additionalData: aad },
      key,
      sealed,
    );
  } catch {
    throw new BackupError('Incorrect password, or the backup file is damaged.');
  }
  try {
    return JSON.parse(new TextDecoder().decode(plain));
  } catch {
    throw new BackupError('The backup decrypted but its contents are damaged.');
  }
}

const sameBytes = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const sameParams = (a, b) => a.version === b.version && a.iterations === b.iterations
  && (a.memoryKib ?? 0) === (b.memoryKib ?? 0) && (a.lanes ?? 0) === (b.lanes ?? 0)
  && sameBytes(a.salt, b.salt);

/**
 * Opens a sealed file with a password, and also returns the key and the
 * parameters it was made with, so the file can be sealed again later
 * without keeping the password.
 */
export async function openSealed(base64Text, password) {
  const parts = split(base64Text);
  // The passphrase in one Unicode form (NFC) first, then exactly as typed,
  // so a file sealed either way, on any device, opens. The app does the
  // same (lib/utils/secret_text.dart).
  const forms = secretForms(password);
  for (let i = 0; i < forms.length; i++) {
    const { key, pinBoxKey } = await deriveKeys(forms[i], parts.params);
    try {
      const parsed = await decryptParts(parts, key);
      return { parsed, key, params: parts.params, pinBoxKey };
    } catch (e) {
      if (i === forms.length - 1 || !(e instanceof BackupError)) throw e;
    }
  }
  throw new BackupError('Wrong password, or the file was changed.');
}

/** [secret] in NFC, then as typed when that differs. */
export function secretForms(secret) {
  const composed = String(secret).normalize('NFC');
  return composed === secret ? [secret] : [composed, secret];
}

/**
 * A key for a brand-new vault: a fresh random salt, the current Argon2id
 * settings, and the key [password] makes with them.
 */
export async function newKey(password) {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const { memoryKib, passes, lanes } = ARGON2_CURRENT;
  const params = { version: 3, iterations: passes, memoryKib, lanes, salt };
  // New keys from the composed form (see secretForms).
  return { key: await deriveKey(String(password).normalize('NFC'), params), params };
}

/**
 * The parameters a file was sealed with, without opening it: what a backup
 * file would need to be read, for tests and for checking a format.
 */
export const paramsOf = (base64Text) => split(base64Text).params;

/**
 * Opens a sealed file with a key kept from an earlier unlock.
 *
 * The key only fits files made with the same parameters. Different ones
 * mean the app sealed it again (a new passphrase, or the stronger format),
 * and the caller has to ask for the passphrase.
 */
export async function openWithKey(base64Text, key, params) {
  const parts = split(base64Text);
  if (!sameParams(parts.params, params)) {
    throw new BackupError('The synced vault was sealed again in the app. Unlock with your passphrase.');
  }
  return decryptParts(parts, key);
}

/**
 * Seals [value] with [key], in the layout its [params] call for: the
 * version it was read in, since without the passphrase no other key can be
 * made. The app upgrades old files when it next writes them.
 */
export async function seal(value, key, params) {
  const aad = params.version >= 2 ? header(params) : new Uint8Array(0);
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, tagLength: MAC_BYTES * 8, additionalData: aad },
    key,
    new TextEncoder().encode(JSON.stringify(value)),
  ));
  const ciphertext = sealed.slice(0, sealed.length - MAC_BYTES);
  const mac = sealed.slice(sealed.length - MAC_BYTES);

  const out = new Uint8Array(aad.length + SALT_BYTES + NONCE_BYTES + MAC_BYTES + ciphertext.length);
  let at = 0;
  out.set(aad, at);
  at += aad.length;
  out.set(params.salt, at);
  at += SALT_BYTES;
  out.set(nonce, at);
  at += NONCE_BYTES;
  out.set(mac, at);
  at += MAC_BYTES;
  out.set(ciphertext, at);
  return bytesToBase64(out);
}

/**
 * Decrypts a backup and returns its entries.
 *
 * Throws {@link BackupError} for both a wrong password and a modified file,
 * which AES-GCM makes indistinguishable on purpose.
 */
export async function decryptBackup(base64Text, password) {
  const { parsed } = await openSealed(base64Text, password);
  return entriesFrom(parsed);
}

/** The live entries in a decrypted backup or sync file. */
export function entriesFrom(parsed) {
  return entriesOf(parsed).map(normaliseEntry).filter((e) => e !== null);
}

export const SYNC_FORMAT = 'ringer-vault-sync';
/**
 * 2 added `generation`: one more than the copy it replaced, inside the
 * encryption, so an older copy put back in Drive shows as older whatever
 * any clock says. A build that knows only 1 refuses to write a version 2
 * file rather than dropping the counter.
 */
export const SYNC_VERSION = 2;

/** A decrypted sync file's generation; 0 for files from before it existed. */
export const generationOf = (parsed) => (Number.isInteger(parsed?.generation) && parsed.generation >= 0
  ? parsed.generation : 0);

/** The copy in Drive is older than one this browser already accepted. */
export class RolledBackError extends BackupError {
  constructor(found, seen) {
    super('The copy in Google Drive is older than one this browser already had '
      + `(version ${found}, after ${seen}). Someone may have put back an earlier `
      + 'copy of the file, so it was not used. If you restored it on purpose, '
      + 'sign out and connect to Google Drive again with your passphrase.');
    this.found = found;
    this.seen = seen;
  }
}

/**
 * The same outer encryption carries two shapes: an exported backup, which is
 * a bare list of entries, and the Google Drive sync file, which wraps its
 * entries with deletions and a version number.
 *
 * Deleted records are dropped here; a fill has no use for them. Saving
 * works on the whole decrypted file instead (see save.js), so deletions
 * are carried through untouched.
 */
function entriesOf(parsed) {
  if (Array.isArray(parsed)) return parsed;

  if (parsed && typeof parsed === 'object' && parsed.format === SYNC_FORMAT) {
    if (typeof parsed.version !== 'number' || parsed.version > SYNC_VERSION) {
      throw new BackupError(
        'This vault was synced by a newer version of Ringer Vault. '
        + 'Update the extension to read it.',
      );
    }
    if (!Array.isArray(parsed.records)) {
      throw new BackupError('The synced vault is damaged.');
    }
    return parsed.records
      .filter((r) => r && typeof r === 'object' && r.deleted !== true)
      .map((r) => r.entry);
  }

  throw new BackupError('The backup decrypted but its contents are damaged.');
}

/**
 * Reads one entry defensively.
 *
 * A backup from an older build is missing every field added since, and a
 * restore that threw on a missing key would make old backups unusable.
 */
function normaliseEntry(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const str = (v) => (typeof v === 'string' ? v : '');
  return {
    id: str(raw.id),
    title: str(raw.title),
    username: str(raw.username),
    email: str(raw.email),
    password: str(raw.password),
    category: str(raw.category),
    notes: str(raw.notes),
    autofillTargets: Array.isArray(raw.autofillTargets)
      ? raw.autofillTargets.filter((t) => typeof t === 'string')
      : [],
  };
}
