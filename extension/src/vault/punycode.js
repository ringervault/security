// Punycode (RFC 3492): how a domain written in other alphabets travels as
// plain letters, "xn--pple-43d" for "аpple" with a Cyrillic "а".
//
// Browsers hand over a host in this form, so a name that looks exactly like
// "apple" on screen arrives as "xn--pple-43d". The look-alike check decodes
// it to compare what a person would actually see. Nothing here decides what
// a site is; host.js still refuses hosts outside plain letters.
//
// The same as lib/autofill/punycode.dart in the app.

const BASE = 36;
const T_MIN = 1;
const T_MAX = 26;
const SKEW = 38;
const DAMP = 700;
const INITIAL_BIAS = 72;
const INITIAL_N = 128;
const MAX_CODE_POINT = 0x10ffff;

const isAscii = (s) => [...s].every((c) => c.codePointAt(0) < 0x80);

/**
 * [label] as a person sees it: "xn--pple-43d" becomes "аpple". Anything not
 * in that form, or not valid, comes back as it was.
 */
export function decodeLabel(label) {
  if (!label.startsWith('xn--')) return label;
  return decode(label.slice(4)) ?? label;
}

/**
 * [urlOrHost] with any host written in other alphabets put into its "xn--"
 * form, as a browser would. Anything else comes back as it was.
 */
export function toAsciiHost(urlOrHost) {
  const value = String(urlOrHost ?? '');
  if (isAscii(value)) return value;
  const scheme = value.indexOf('://');
  const start = scheme === -1 ? 0 : scheme + 3;
  let end = value.length;
  for (const stop of ['/', '?', '#', ':']) {
    const at = value.indexOf(stop, start);
    if (at !== -1 && at < end) end = at;
  }
  const host = value
    .slice(start, end)
    .toLowerCase()
    .split('.')
    .map((label) => (isAscii(label) ? label : `xn--${encode(label)}`))
    .join('.');
  return value.slice(0, start) + host + value.slice(end);
}

function decode(input) {
  const output = [];
  let basic = input.lastIndexOf('-');
  if (basic < 0) basic = 0;
  for (let j = 0; j < basic; j++) {
    const c = input.charCodeAt(j);
    if (c >= 0x80) return null;
    output.push(c);
  }
  let n = INITIAL_N;
  let i = 0;
  let bias = INITIAL_BIAS;
  let index = basic > 0 ? basic + 1 : 0;
  while (index < input.length) {
    const oldI = i;
    let w = 1;
    for (let k = BASE; ; k += BASE) {
      if (index >= input.length) return null;
      const digit = digitOf(input.charCodeAt(index++));
      if (digit >= BASE) return null;
      i += digit * w;
      if (i > MAX_CODE_POINT * 64) return null;
      const t = k <= bias ? T_MIN : k >= bias + T_MAX ? T_MAX : k - bias;
      if (digit < t) break;
      w *= BASE - t;
    }
    const out = output.length + 1;
    bias = adapt(i - oldI, out, oldI === 0);
    n += Math.floor(i / out);
    i %= out;
    if (n > MAX_CODE_POINT) return null;
    output.splice(i, 0, n);
    i++;
  }
  return String.fromCodePoint(...output);
}

function encode(label) {
  const input = [...label].map((c) => c.codePointAt(0));
  let output = input.filter((c) => c < 0x80).map((c) => String.fromCharCode(c)).join('');
  const b = output.length;
  let h = b;
  if (b > 0) output += '-';
  let n = INITIAL_N;
  let delta = 0;
  let bias = INITIAL_BIAS;
  while (h < input.length) {
    const m = Math.min(...input.filter((c) => c >= n));
    delta += (m - n) * (h + 1);
    n = m;
    for (const c of input) {
      if (c < n) delta++;
      if (c !== n) continue;
      let q = delta;
      for (let k = BASE; ; k += BASE) {
        const t = k <= bias ? T_MIN : k >= bias + T_MAX ? T_MAX : k - bias;
        if (q < t) break;
        output += charOf(t + ((q - t) % (BASE - t)));
        q = Math.floor((q - t) / (BASE - t));
      }
      output += charOf(q);
      bias = adapt(delta, h + 1, h === b);
      delta = 0;
      h++;
    }
    delta++;
    n++;
  }
  return output;
}

function digitOf(c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30 + 26;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61;
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  return BASE;
}

const charOf = (digit) => String.fromCharCode(digit < 26 ? 0x61 + digit : 0x30 + digit - 26);

function adapt(delta, points, first) {
  delta = first ? Math.floor(delta / DAMP) : Math.floor(delta / 2);
  delta += Math.floor(delta / points);
  let k = 0;
  while (delta > Math.floor(((BASE - T_MIN) * T_MAX) / 2)) {
    delta = Math.floor(delta / (BASE - T_MIN));
    k += BASE;
  }
  return k + Math.floor(((BASE - T_MIN + 1) * delta) / (delta + SKEW));
}
