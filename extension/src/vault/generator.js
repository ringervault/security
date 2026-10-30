// Makes up passwords, as lib/utils/password_generator.dart does in the app:
// the same character sets, the same rule for which special characters a
// site allows, and one of each chosen kind in every password.

const LOWER = 'abcdefghijkmnopqrstuvwxyz';
const UPPER = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const DIGITS = '23456789';

// Left out above: l, I, 1, O, 0. A password read off a screen and typed
// somewhere else "doesn't work" mostly because of those.

/** The special characters used unless the user narrows them. */
export const DEFAULT_SYMBOLS = '!@#$%^&*-_=+?';

export const MIN_LENGTH = 8;
export const MAX_LENGTH = 64;
export const DEFAULT_LENGTH = 20;

/**
 * The special characters in [raw] a password can use: printable ASCII that
 * is neither a letter, a digit nor a space, each once, in the order typed.
 * Spaces, letters and digits are dropped rather than refused, so a site's
 * list can be pasted with its spaces ("! @ # $").
 */
export function cleanSymbols(raw) {
  let out = '';
  for (const ch of String(raw ?? '')) {
    const c = ch.codePointAt(0);
    const printable = c >= 0x21 && c <= 0x7e;
    const letterOrDigit = /[A-Za-z0-9]/.test(ch);
    if (printable && !letterOrDigit && !out.includes(ch)) out += ch;
  }
  return out;
}

/** A whole number below [n], with no lean towards any of them. */
function below(n, random) {
  const limit = Math.floor(0x100000000 / n) * n;
  const word = new Uint32Array(1);
  for (;;) {
    random(word);
    if (word[0] < limit) return word[0] % n;
  }
}

const pick = (pool, random) => pool[below(pool.length, random)];

function pools({ lowercase, uppercase, digits, symbols, allowedSymbols }) {
  const special = cleanSymbols(allowedSymbols);
  const chosen = [
    lowercase && LOWER,
    uppercase && UPPER,
    digits && DIGITS,
    symbols && special !== '' && special,
  ].filter(Boolean);
  // Nothing usable chosen: letters and numbers rather than a weak set, and
  // never special characters the user has ruled out. The screen does not
  // let the last kind be turned off, so this is only a guard.
  return chosen.length > 0 ? chosen : [LOWER, UPPER, DIGITS];
}

/**
 * A new password. [random] fills a Uint32Array with secure random numbers
 * (crypto.getRandomValues), replaceable in tests.
 */
export function generatePassword({
  length = DEFAULT_LENGTH,
  lowercase = true,
  uppercase = true,
  digits = true,
  symbols = true,
  allowedSymbols = DEFAULT_SYMBOLS,
} = {}, random = (array) => crypto.getRandomValues(array)) {
  const chosen = pools({ lowercase, uppercase, digits, symbols, allowedSymbols });
  const size = Math.min(MAX_LENGTH, Math.max(MIN_LENGTH, Math.round(Number(length) || DEFAULT_LENGTH)));
  // One of each kind first, so turning a kind on guarantees it is there.
  const chars = chosen.map((pool) => pick(pool, random));
  const all = chosen.join('');
  while (chars.length < size) chars.push(pick(all, random));
  // Shuffled, or the guaranteed ones would always lead.
  for (let i = chars.length - 1; i > 0; i--) {
    const j = below(i + 1, random);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

/** Roughly how many bits of strength the choices give. */
export function entropyBits({
  length = DEFAULT_LENGTH,
  lowercase = true,
  uppercase = true,
  digits = true,
  symbols = true,
  allowedSymbols = DEFAULT_SYMBOLS,
} = {}) {
  const size = pools({ lowercase, uppercase, digits, symbols, allowedSymbols }).join('').length;
  return length * Math.log2(size);
}

/** Whether [options] still chooses some kind of character. */
export function choosesSomething({ lowercase, uppercase, digits, symbols, allowedSymbols }) {
  return Boolean(lowercase || uppercase || digits || (symbols && cleanSymbols(allowedSymbols) !== ''));
}

/** "Strong" and the like, by the same thresholds as the app. */
export function strengthLabel(bits) {
  if (bits >= 100) return 'Excellent';
  if (bits >= 80) return 'Strong';
  if (bits >= 60) return 'Reasonable';
  return 'Weak';
}
