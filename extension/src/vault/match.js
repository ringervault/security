// Decides which saved entries may be offered for the page in front of you.
//
// Mirrors the rules in lib/autofill/autofill_target.dart. The important one
// is that a title is never matched against a site: a title is a label the
// user typed, and an attacker controls the page, so "PayPal" in one and
// "paypal" in the other proves nothing.

import {
  hostOf, isLoopback, isPunycode, registrableDomain, siteTier, SiteTier,
} from './host.js';

/** Targets are stored as "site:example.com" or "app:package:sha256". */
export function siteTargetsOf(entry) {
  return (entry.autofillTargets ?? [])
    .filter((t) => t.startsWith('site:'))
    .map((t) => t.slice('site:'.length))
    .filter((v) => v !== '');
}

export const MatchStrength = {
  /** Saved for exactly this address. */
  saved: 'saved',
  /** Saved for another address on the same site; confirm before filling. */
  sameSite: 'sameSite',
  /** The site matches but the page is plain http; confirm, every time. */
  insecure: 'insecure',
  /** Nothing links the entry to this site; the user must confirm. */
  unconfirmed: 'unconfirmed',
};

const STRENGTH = {
  [SiteTier.exact]: MatchStrength.saved,
  [SiteTier.sameSite]: MatchStrength.sameSite,
  [SiteTier.insecure]: MatchStrength.insecure,
};

/**
 * Splits the vault for a given page.
 *
 * Entries saved for this exact address come first; entries saved for
 * another address on the same site, or matching a plain-http page, follow
 * and ask before filling. Everything else is offered separately and only
 * fills after an explicit confirmation, so the extension never decides on
 * its own that two names look alike.
 */
export function candidatesFor(entries, pageUrl) {
  let scheme = null;
  try {
    scheme = new URL(pageUrl).protocol.replace(':', '');
  } catch {
    // A bare host, as in tests: no scheme to judge.
  }
  if (scheme && scheme !== 'https' && scheme !== 'http') {
    return empty('notAWebPage');
  }

  const host = hostOf(pageUrl);
  if (!host.isUsable) return empty(host.rejection);

  const matched = [];
  const others = [];
  for (const entry of entries) {
    const saved = siteTargetsOf(entry);
    const tier = siteTier(saved, host.host, scheme);
    if (tier === SiteTier.none) {
      others.push({ entry, strength: MatchStrength.unconfirmed, savedFor: [] });
    } else {
      matched.push({
        entry,
        strength: STRENGTH[tier],
        savedFor: saved.filter(
          (s) => registrableDomain(s).registrable === host.registrable,
        ),
      });
    }
  }

  const order = [MatchStrength.saved, MatchStrength.sameSite, MatchStrength.insecure];
  const byTitle = (a, b) => a.entry.title.localeCompare(b.entry.title);
  return {
    domain: host.host,
    rejection: null,
    insecure: scheme === 'http' && !isLoopback(host.host),
    punycode: isPunycode(host.registrable),
    matched: matched.sort(
      (a, b) => order.indexOf(a.strength) - order.indexOf(b.strength) || byTitle(a, b),
    ),
    others: others.sort(byTitle),
  };
}

function empty(rejection) {
  return {
    domain: null, rejection, insecure: false, punycode: false,
    matched: [], others: [],
  };
}

/**
 * The entries from [others] (not linked to this page's site) worth
 * suggesting under a login field: those whose title, username or email
 * names the site, as "Amazon" does on amazon.in. Picking one still asks
 * first, and is then linked to the site.
 *
 * A name is a hint, never a reason to fill: the page is the attacker's to
 * choose, which is why this runs only where the site is not dressed as one
 * already in the vault (the caller checks), and why the list asks before
 * filling. Names shorter than three letters suggest nothing.
 */
export function suggestedFor(others, pageUrl) {
  const host = hostOf(pageUrl);
  if (!host.isUsable) return [];
  const name = host.registrable.split('.')[0].toLowerCase();
  if (name.length < 3) return [];
  return others.filter(({ entry }) =>
    [entry.title, entry.username, entry.email]
      .some((v) => typeof v === 'string' && v.toLowerCase().includes(name)));
}
