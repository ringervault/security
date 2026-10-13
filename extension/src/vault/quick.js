// Quick unlock: a PIN, or Touch ID / Windows Hello, in place of typing the
// sync passphrase every time.
//
// Neither replaces the passphrase. Both keep a sealed copy of it, and give it
// back to the normal unlock when the PIN or the fingerprint is right. What
// differs is where that copy may live:
//
// - PIN. A 4 to 12 digit PIN is far too few guesses to protect anything on
//   disk: every PIN could be tried in seconds. So the PIN-sealed copy lives
//   only in chrome.storage.session, which is held in memory and cleared when
//   the browser closes, and five wrong PINs delete it. On disk there is only
//   the PIN itself, sealed with a key from the vault's own Argon2id
//   derivation (format.js, deriveKeys), so the PIN can be turned back on by
//   the first passphrase unlock after a restart without asking for it, and a
//   copy of the browser's storage is no cheaper to guess at than the vault.
//
// - Fingerprint, with the WebAuthn PRF extension. The authenticator (Touch
//   ID through iCloud Keychain, Windows Hello) hands back a 32-byte secret
//   only after the fingerprint or face is checked, and the same secret every
//   time. That secret seals the passphrase on disk, so it survives restarts:
//   the sealed copy is useless without the finger.
//
// - Fingerprint without PRF (Chrome's older profile authenticator has none).
//   The fingerprint can then only confirm it is you, not unseal anything, so
//   it works like the PIN: a copy in memory for this browser session only.

const ITERATIONS_PIN = 600_000;
const ITERATIONS_PASSPHRASE = 100_000;
const IV_BYTES = 12;

export const PIN_MIN = 4;
export const PIN_MAX = 12;
export const PIN_TRIES = 5;

/** Why [pin] cannot be used, or null when it can. */
export function pinProblem(pin) {
  if (!/^[0-9]*$/.test(pin)) return 'Use digits only.';
  if (pin.length < PIN_MIN) return `Use at least ${PIN_MIN} digits.`;
  if (pin.length > PIN_MAX) return `Use at most ${PIN_MAX} digits.`;
  if (new Set(pin).size === 1) return 'Do not repeat one digit.';
  return null;
}

export function toBase64(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = '';
  for (let i = 0; i < view.length; i++) binary += String.fromCharCode(view[i]);
  return btoa(binary);
}

export function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export const randomBytes = (n) => crypto.getRandomValues(new Uint8Array(n));

async function stretch(secret, salt, iterations) {
  const material = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret), 'PBKDF2', false, ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

/** The key a PIN makes with [salt]. */
export const pinKey = (pin, salt) => stretch(pin, salt, ITERATIONS_PIN);

/**
 * The key earlier versions sealed the PIN on disk with: read only to move an
 * existing PIN to the current key (background.js, armQuick).
 */
export const passphraseKey = (passphrase, salt) =>
  stretch(passphrase, salt, ITERATIONS_PASSPHRASE);

/** A key from raw secret bytes: a PRF output, or a random session key. */
export async function bytesKey(bytes) {
  const material = await crypto.subtle.importKey('raw', bytes, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('Ringer Vault quick unlock v1'),
    },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

/** [text] sealed with [key], as JSON-safe strings. */
export async function sealText(text, key) {
  const iv = randomBytes(IV_BYTES);
  const data = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key, new TextEncoder().encode(text),
  );
  return { iv: toBase64(iv), data: toBase64(data) };
}

/** The text in [box], or null when [key] is the wrong one. */
export async function openText(box, key) {
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: fromBase64(box.iv) }, key, fromBase64(box.data),
    );
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}
