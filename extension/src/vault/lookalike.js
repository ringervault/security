// Whether a website is dressed up as one the user already trusts.
//
// Matching never fills across sites: "amaz0n.in" is simply a different site
// from "amazon.in" and gets nothing on its own. The risk is the moment a
// person is asked "fill this here anyway?" and says yes, or types their
// password in by hand. This names what the page is imitating at exactly that
// moment.
//
// The list of real sites is the user's own vault (every site a login is saved
// for), then the well-known services in known_sites.js. So it works offline,
// sends nothing anywhere, and is personal: the bank a person actually uses is
// in it even though no fixed table would be. A site already in the vault is
// never called a look-alike, whatever it resembles.
//
// The same logic as lib/autofill/lookalike.dart in the app;
// test/fixtures/lookalike_cases.json holds cases both must agree on.

import { hostOf, registrableDomain } from './host.js';
import { knownBrands } from './known_sites.js';
import { decodeLabel, toAsciiHost } from './punycode.js';

export const LookalikeKind = {
  /**
   * Characters that read the same: "amaz0n", "paypa1", "rnicrosoft", or
   * letters from another alphabet such as a Cyrillic "а" in "аmazon" (which
   * arrives as "xn--mazon-3ve").
   */
  confusable: 'confusable',
  /** One letter off, or two for long names: "amazom", "amzaon". */
  typo: 'typo',
  /** The real name inside another address: "paypal-login.com". */
  embedded: 'embedded',
  /** The same name under another ending; companies often own several. */
  sameName: 'sameName',
  /**
   * Letters from two alphabets in one part of the address, such as a
   * Cyrillic "а" among Latin letters. Said whatever it resembles.
   */
  mixedScripts: 'mixedScripts',
  /**
   * Written entirely in letters from another alphabet that all pass for
   * Latin ones, under an ending in Latin letters: "сосо.com". Said whatever
   * it resembles.
   */
  disguisedScript: 'disguisedScript',
};

/** Shorter names ("bt", "x") match far too much to say anything. */
const MIN_NAME = 3;
const MIN_EMBEDDED = 5;
const CONFUSABLES = { 0: 'o', 1: 'l' };

/**
 * Letters from other alphabets that read as a Latin one (from Unicode's list
 * of confusable characters), and Latin letters with marks, under the letter
 * they pass for. The same table as lib/autofill/lookalike.dart's.
 */
const READS_AS = {
  a: 'аɑαàáâãäåāăąǎǟǡǻȁȃȧ',
  b: 'ƅ',
  c: 'сϲçćĉċč',
  d: 'ԁďđ',
  e: 'еҽèéêëēĕėęěȅȇȩ',
  g: 'ɡցĝğġģǧǵ',
  h: 'һհĥȟħ',
  i: 'іıɩιìíîïĩīĭįǐȉȋ',
  j: 'јϳĵǰ',
  k: 'κкķǩ',
  l: 'ӏĺļľł',
  n: 'ոñńņňǹ',
  o: 'оοօσòóôõöōŏőơǒǫǭȍȏȫȭȯȱø',
  p: 'рρ',
  q: 'ԛզ',
  r: 'гŕŗřȑȓ',
  s: 'ѕśŝşšș',
  t: 'ţťțŧ',
  u: 'սυʋùúûüũūŭůűųưǔǖǘǚǜȕȗ',
  v: 'νѵ',
  w: 'ԝѡŵ',
  x: 'хχ',
  y: 'уүγýÿŷȳ',
  z: 'źżž',
};

const READS_AS_LETTER = new Map(
  Object.entries(READS_AS).flatMap(([letter, others]) => [...others].map((c) => [c, letter])),
);

/**
 * The sites to compare against: [vaultSites] (hosts or addresses saved in
 * entries) first, then the brand table, as {site, brand}; brand is null for
 * a site from the vault.
 */
export function knownSites(vaultSites) {
  const seen = new Set();
  const out = [];
  for (const saved of vaultSites) {
    const site = hostOf(toAsciiHost(saved)).registrable;
    if (site && !seen.has(site)) {
      seen.add(site);
      out.push({ site, brand: null });
    }
  }
  for (const brand of knownBrands) {
    for (const domain of brand.domains) {
      const site = registrableDomain(domain).registrable;
      if (site && !seen.has(site)) {
        seen.add(site);
        out.push({ site, brand: brand.name });
      }
    }
  }
  return out;
}

/**
 * What [pageHost] looks like, as {kind, like, page, danger}, or null when it
 * looks like nothing known (or is itself known). The most serious kind wins;
 * within a kind, the user's own sites before the brand table. For the
 * alphabet checks, like is null and page is the whole address.
 */
export function lookalikeOf(pageHost, known) {
  return lookalikesOf(pageHost, known)[0] ?? null;
}

/**
 * Everything [pageHost] gives away about itself, at most one of each kind,
 * most serious first; empty when it looks like nothing known (or is itself
 * known). The same as lookalikesOf in lib/autofill/lookalike.dart.
 */
export function lookalikesOf(pageHost, known) {
  // A host in other alphabets is put into its "xn--" form first, as a
  // browser would have; most already arrive that way.
  const page = hostOf(toAsciiHost(pageHost));
  const registrable = page.registrable;
  if (!registrable) return [];
  if (known.some((k) => k.site === registrable)) return [];

  const name = nameOf(registrable);
  const suffix = registrable.slice(name.length + 1);
  const nameSkeleton = skeleton(name);
  const front = page.host.slice(0, page.host.length - suffix.length - 1);
  // Each label decoded first, so the hyphens of "xn--" do not split it.
  const parts = front.split('.').flatMap((label) => decodeLabel(label).split('-')).filter(Boolean);

  const found = (kind, test) => {
    for (const k of known) {
      const kName = nameOf(k.site);
      if (kName.length < MIN_NAME) continue;
      if (test(k, kName)) {
        return { kind, like: k, page: registrable, danger: kind !== LookalikeKind.sameName, alphabets: [] };
      }
    }
    return null;
  };

  return [
    found(LookalikeKind.confusable,
      (k, kName) => name !== kName && nameSkeleton === skeleton(kName)),
    found(LookalikeKind.typo, (k, kName) => {
      const a = nameSkeleton;
      const b = skeleton(kName);
      if (a === b) return false;
      // Short names are a letter away from ordinary words ("apple",
      // "apply"), so only longer ones count.
      const allowed = kName.length >= 10 ? 2 : kName.length >= 6 ? 1 : 0;
      return allowed > 0 && distance(a, b, allowed) <= allowed;
    }),
    found(LookalikeKind.embedded, (k, kName) => {
      if (`.${page.host}.`.includes(`.${k.site}.`)) return true;
      if (kName.length < MIN_EMBEDDED) return false;
      const want = skeleton(kName);
      return nameSkeleton !== want && parts.some((p) => skeleton(p) === want);
    }),
    ...scriptsOf(front.split('.'), suffix, page.host),
    // A shared name only asks for a closer look, so it comes after anything
    // that is a reason to stop.
    found(LookalikeKind.sameName,
      (k, kName) => name === kName && suffix !== k.site.slice(kName.length + 1)),
  ].filter(Boolean);
}

/**
 * The checks that need no known site: [labels] (everything in front of the
 * ending) mixing alphabets, or written wholly in letters that pass for Latin
 * ones under an ending in Latin letters. At most one of each.
 */
function scriptsOf(labels, suffix, host) {
  const latinEnding = suffix.split('.').every((l) => !l.startsWith('xn--'));
  const flagged = (kind, alphabets) => ({ kind, like: null, page: host, danger: true, alphabets });
  let mixed = null;
  let disguised = null;
  for (const label of labels) {
    const chars = [...decodeLabel(label)];
    const scripts = new Set(chars.map(scriptOf).filter((s) => s !== null));
    if (![...scripts].some((s) => PASSES_FOR_LATIN.has(s))) continue;
    const alphabets = SCRIPTS.filter((s) => scripts.has(s)).map((s) => ALPHABET_NAMES[s]);
    if (scripts.size > 1) {
      mixed ??= flagged(LookalikeKind.mixedScripts, alphabets);
      continue;
    }
    const letters = chars.filter((c) => scriptOf(c) !== null);
    if (latinEnding && letters.every((c) => READS_AS_LETTER.has(c))) {
      disguised ??= flagged(LookalikeKind.disguisedScript, alphabets);
    }
  }
  return [mixed, disguised].filter(Boolean);
}

/** In the order they are named: Latin first. */
const SCRIPTS = ['latin', 'greek', 'cyrillic', 'armenian', 'other'];
const ALPHABET_NAMES = {
  latin: 'Latin', greek: 'Greek', cyrillic: 'Cyrillic', armenian: 'Armenian', other: 'another alphabet',
};

/** The alphabets with letters that pass for Latin ones. */
const PASSES_FOR_LATIN = new Set(['greek', 'cyrillic', 'armenian']);

/** Which alphabet [c] belongs to, or null for a digit or hyphen. */
function scriptOf(c) {
  const r = c.codePointAt(0);
  if (r === 0x2d || (r >= 0x30 && r <= 0x39)) return null;
  if ((r >= 0x61 && r <= 0x7a) || (r >= 0xc0 && r <= 0x2af) || (r >= 0x1e00 && r <= 0x1eff)) {
    return 'latin';
  }
  if ((r >= 0x370 && r <= 0x3ff) || (r >= 0x1f00 && r <= 0x1fff)) return 'greek';
  if ((r >= 0x400 && r <= 0x52f) || (r >= 0x1c80 && r <= 0x1c8f)
    || (r >= 0x2de0 && r <= 0x2dff) || (r >= 0xa640 && r <= 0xa69f)) {
    return 'cyrillic';
  }
  if (r >= 0x530 && r <= 0x58f) return 'armenian';
  return 'other';
}

const nameOf = (registrable) => registrable.slice(0, registrable.indexOf('.'));

/**
 * The name as it reads: an "xn--" name decoded to what is shown, letters
 * from other alphabets and with marks read as the plain letter, confusable
 * characters folded, hyphens dropped.
 */
function skeleton(name) {
  const read = [...decodeLabel(name)].map((c) => READS_AS_LETTER.get(c) ?? c).join('');
  const s = read.replaceAll('-', '').replaceAll('rn', 'm').replaceAll('vv', 'w');
  return [...s].map((c) => CONFUSABLES[c] ?? c).join('');
}

/** Edit distance, a swap of neighbours counting once. */
function distance(a, b, limit) {
  if (Math.abs(a.length - b.length) > limit) return limit + 1;
  const rows = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = 0; i <= a.length; i++) rows[i][0] = i;
  for (let j = 0; j <= b.length; j++) rows[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let best = Math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        best = Math.min(best, rows[i - 2][j - 2] + 1);
      }
      rows[i][j] = best;
    }
  }
  return rows[a.length][b.length];
}

/** "Latin and Cyrillic", "Latin, Greek and Cyrillic". */
const both = (names) => (names.length < 2
  ? names.join('')
  : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`);

/** The warning in words, the same as the app's. */
export function describeLookalike(l) {
  if (l.kind === LookalikeKind.mixedScripts) {
    return `${l.page} mixes ${both(l.alphabets)} letters in one name. Real `
      + 'sites almost never do; scam sites do it so an address looks like '
      + 'one you know.';
  }
  if (l.kind === LookalikeKind.disguisedScript) {
    return `${l.page} is written entirely in ${l.alphabets[0]} letters `
      + 'that look like English ones, so it can pass for a different '
      + 'address. Scam sites do this.';
  }
  const whose = l.like.brand === null ? ', where you have a login' : `, ${l.like.brand}'s site`;
  const foreignLetters = l.page.split('.').some((label) => label.startsWith('xn--'));
  if (l.kind === LookalikeKind.confusable && foreignLetters) {
    // Shown in the form that cannot pass for the real one.
    return `${l.page} is spelled with letters from another alphabet so it `
      + `looks exactly like ${l.like.site}${whose}. It is a different site. `
      + 'Scam sites copy names this way.';
  }
  switch (l.kind) {
    case LookalikeKind.embedded:
      return `${l.page} uses the name "${nameOf(l.like.site)}" in its address, `
        + `but it is not ${l.like.site}${whose}. Scam sites copy names this way.`;
    case LookalikeKind.sameName:
      return `${l.page} has the same name as ${l.like.site}${whose}, with a `
        + 'different ending. Companies often own both, but so do scam sites. '
        + 'Check this is where you meant to sign in.';
    default:
      return `${l.page} looks like ${l.like.site}${whose}, but it is a different `
        + 'site. Scam sites copy names this way.';
  }
}
