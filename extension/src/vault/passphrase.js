// The rule a new sync passphrase has to meet.
//
// The same rule as the app's (syncPassphraseProblem in
// lib/utils/passphrase_strength.dart), so a passphrase created here is one
// the app would have accepted, and the other way round. Besides length and
// variety, it has to be hard to guess: see estimateBits. The sync file sits
// in Google Drive, where a copy can be guessed at offline as fast as the
// attacker's hardware allows, so this passphrase matters more than any
// other. test/fixtures/passphrase_cases.json holds cases both must agree on.

import { commonWords } from './common_words.js';
import { effWords } from './eff_words.js';

export const MIN_LENGTH = 12;
export const MAX_LENGTH = 128;

/** Below this a sync passphrase is refused. */
export const MIN_BITS = 50;

/** Why [value] is not good enough, or null when it is. */
export function passphraseProblem(value) {
  if (value.length < MIN_LENGTH) {
    const short = MIN_LENGTH - value.length;
    return `Add ${short} more ${short === 1 ? 'character' : 'characters'}. Minimum is ${MIN_LENGTH}.`;
  }
  if (value.length > MAX_LENGTH) return `Keep it under ${MAX_LENGTH} characters.`;
  // Never silently trimmed: the untrimmed value is what seals the backup, so
  // a stray space would lock it for ever.
  if (value.trim().length !== value.length) return 'Remove the space at the start or end.';
  if (new Set(value).size < 5) {
    return 'Use more variety. A repeated pattern is as weak as a short one.';
  }
  const bits = estimateBits(value);
  if (bits < MIN_BITS) {
    return `Too easy to guess: about ${Math.round(bits)} bits, and it needs ${MIN_BITS}. `
      + 'Common words, names, years and keyboard runs count for little. '
      + 'Try four or five unrelated words.';
  }
  return null;
}

/** The strength as typed, in words, for under the field. */
export function describeBits(bits) {
  const label = bits < MIN_BITS ? 'Too easy to guess'
    : bits < 65 ? 'Fair' : bits < 80 ? 'Strong' : 'Very strong';
  return `${label} · about ${Math.round(bits)} bits`;
}

/**
 * How many guesses [value] would take, in bits, counted the way an attacker
 * guesses: common words and passwords (after undoing look-alikes such as 0
 * for o), keyboard runs, sequences, repeats and years cost only a few bits;
 * anything else costs per character. The same as estimateBits in the app.
 */
export function estimateBits(value) {
  const lower = value.toLowerCase();
  const norm = [...lower].map((c) => LOOK_ALIKES[c] ?? c).join('');
  let bits = 0;
  let i = 0;
  while (i < value.length) {
    const [length, cost] = bestPiece(value, lower, norm, i);
    bits += cost;
    i += length;
  }
  return bits;
}

const LOOK_ALIKES = {
  0: 'o', 1: 'i', 3: 'e', 4: 'a', 5: 's', 7: 't', 8: 'b', '@': 'a', $: 's', '!': 'i', '+': 't',
};
const KEYBOARD_ROWS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm', '1234567890'];
const log2 = Math.log2;

// The passphrase word list (the EFF list the app's generator draws from): a
// word from it costs log2 of the list's size, whatever its length.
const LIST_WORDS = new Set(effWords);
const LONGEST_LIST_WORD = effWords.reduce((m, w) => Math.max(m, w.length), 0);
const LIST_WORD_BITS = log2(effWords.length);

function bestPiece(original, lower, norm, i) {
  const options = [];

  commonWords.forEach((w, rank) => {
    if (w.length < 3 || !norm.startsWith(w, i)) return;
    const piece = original.slice(i, i + w.length);
    const cost = log2(rank + 1) + 1
      + (piece !== piece.toLowerCase() ? 1 : 0)
      + (lower.slice(i, i + w.length) !== w ? 1 : 0);
    options.push([w.length, cost]);
  });

  for (let len = Math.min(LONGEST_LIST_WORD, lower.length - i); len >= 3; len--) {
    const w = lower.slice(i, i + len);
    if (!LIST_WORDS.has(w)) continue;
    const piece = original.slice(i, i + len);
    options.push([len, LIST_WORD_BITS + (piece !== w ? 1 : 0)]);
    break;
  }

  let r = i + 1;
  while (r < lower.length && lower[r] === lower[i]) r++;
  if (r - i >= 3) options.push([r - i, classBits(original[i]) + log2(r - i)]);

  if (i + 2 < lower.length) {
    const step = lower.charCodeAt(i + 1) - lower.charCodeAt(i);
    if (step === 1 || step === -1) {
      let s = i + 1;
      while (s + 1 < lower.length && lower.charCodeAt(s + 1) - lower.charCodeAt(s) === step) s++;
      if (s - i + 1 >= 3) options.push([s - i + 1, classBits(original[i]) + log2(s - i + 1)]);
    }
  }

  for (const row of KEYBOARD_ROWS) {
    for (const line of [row, [...row].reverse().join('')]) {
      for (let len = Math.min(line.length, lower.length - i); len >= 4; len--) {
        if (line.includes(lower.slice(i, i + len))) {
          options.push([len, 4 + log2(len)]);
          break;
        }
      }
    }
  }

  if (i + 4 <= lower.length) {
    const four = lower.slice(i, i + 4);
    const y = Number(four);
    if (/^\d{4}$/.test(four) && y >= 1900 && y <= 2039) options.push([4, 7]);
  }

  options.push([1, classBits(original[i])]);

  options.sort((a, b) => (a[0] !== b[0] ? b[0] - a[0] : a[1] - b[1]));
  return options[0];
}

function classBits(c) {
  if (/[a-z]/.test(c)) return 4;
  if (/[A-Z]/.test(c)) return 4.7;
  if (/[0-9]/.test(c)) return log2(10);
  if (' -_.'.includes(c)) return 2;
  return 5;
}

