// Host handling for matching a saved credential to a website.
//
// The same logic as lib/autofill/registrable_domain.dart in the app.
// Matching is a security decision rather than a string convenience, so this
// refuses rather than guesses: no "contains", no prefix test, no similarity
// score. test/fixtures/autofill_cases.json holds cases both must agree on.

import { pslRules, pslWildcards, pslExceptions } from './public_suffix_data.js';

export const HostRejection = {
  malformed: 'malformed',
  nonAscii: 'nonAscii',
  ipAddress: 'ipAddress',
  publicSuffixOnly: 'publicSuffixOnly',
};

const ASCII_HOST = /^[a-z0-9.-]+$/;
const LOOKS_LIKE_IP = /^[0-9.]+$/;

// The Public Suffix List, loaded on first use. Bundled rather than fetched,
// because a security decision should not depend on a download.
let psl = null;
function suffixes() {
  psl ??= {
    rules: new Set(pslRules.split('\n')),
    wildcards: new Set(pslWildcards.split('\n')),
    exceptions: new Set(pslExceptions.split('\n')),
  };
  return psl;
}

// How many labels at the end form the public suffix: an exception rule wins
// outright and gives up its leftmost label; otherwise the longest matching
// rule wins; otherwise the last label alone.
function suffixLength(labels) {
  const { rules, wildcards, exceptions } = suffixes();
  for (let i = 0; i < labels.length; i++) {
    if (exceptions.has(labels.slice(i).join('.'))) return labels.length - i - 1;
  }
  for (let i = 0; i < labels.length; i++) {
    if (rules.has(labels.slice(i).join('.'))) return labels.length - i;
    if (i + 1 < labels.length && wildcards.has(labels.slice(i + 1).join('.'))) {
      return labels.length - i;
    }
  }
  return 1;
}

const ok = (registrable, host) => ({
  registrable, host, rejection: null, isUsable: true,
});
const rejected = (rejection) => ({
  registrable: null, host: null, rejection, isUsable: false,
});

/**
 * Reduces a host to the domain a credential can belong to, and normalises
 * the host itself (lower case, no trailing dot, no "www." in front of the
 * site's name).
 */
export function registrableDomain(rawHost) {
  let host = String(rawHost ?? '').trim().toLowerCase();
  if (host.endsWith('.')) host = host.slice(0, -1);

  if (host === '' || host.includes('/') || host.includes(' ')) {
    return rejected(HostRejection.malformed);
  }
  if (!ASCII_HOST.test(host)) return rejected(HostRejection.nonAscii);
  if (LOOKS_LIKE_IP.test(host) || host.includes(':')) {
    return rejected(HostRejection.ipAddress);
  }
  // This computer itself: a site of its own, for logins to things being
  // built or run here. Nothing on the network can answer for it.
  if (host === 'localhost') return ok(host, host);

  const labels = host.split('.');
  if (labels.length < 2 || labels.some((l) => l === '')) {
    return rejected(HostRejection.malformed);
  }

  const n = suffixLength(labels);
  if (labels.length <= n) return rejected(HostRejection.publicSuffixOnly);

  const registrable = labels.slice(labels.length - n - 1).join('.');
  // "www." is dropped only when it is a subdomain in front of the site's
  // name. In "www.ck" it is the name itself, and must stay.
  const isWwwSubdomain = labels[0] === 'www' && labels.length > n + 1;
  return ok(registrable, isWwwSubdomain ? labels.slice(1).join('.') : host);
}

/** Pulls the host out of a URL or a bare host string. */
export function hostOf(urlOrHost) {
  const value = String(urlOrHost ?? '').trim();
  if (value === '') return rejected(HostRejection.malformed);

  if (value.includes('://')) {
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      return rejected(HostRejection.malformed);
    }
    if (!parsed.hostname) return rejected(HostRejection.malformed);
    return registrableDomain(parsed.hostname);
  }

  const slash = value.indexOf('/');
  return registrableDomain(slash === -1 ? value : value.slice(0, slash));
}

/** How a page relates to the websites an entry was saved for. */
export const SiteTier = {
  exact: 'exact',
  sameSite: 'sameSite',
  insecure: 'insecure',
  none: 'none',
};

/**
 * Compares a page against an entry's saved websites. [scheme] is "https",
 * "http", or null when unknown, which is treated as secure.
 */
export function siteTier(savedHosts, pageHost, scheme = null) {
  const page = registrableDomain(pageHost);
  if (!page.isUsable) return SiteTier.none;

  let sameSite = false;
  let exact = false;
  for (const saved of savedHosts) {
    const target = registrableDomain(saved);
    if (!target.isUsable || target.registrable !== page.registrable) continue;
    sameSite = true;
    if (target.host === page.host) exact = true;
  }

  if (!sameSite) return SiteTier.none;
  if (scheme && scheme.toLowerCase() === 'http' && !isLoopback(page.host)) return SiteTier.insecure;
  return exact ? SiteTier.exact : SiteTier.sameSite;
}

/**
 * "localhost" and names under it ("app.localhost"): this computer itself.
 * Browsers never send them to the network, so plain http there cannot be
 * changed on the way.
 */
export function isLoopback(host) {
  const name = String(host ?? '').toLowerCase().replace(/\.$/, '');
  return name === 'localhost' || name.endsWith('.localhost');
}

/** A page nobody on the network could have changed: https, or this computer. */
export function isSecurePage(url) {
  try {
    const { protocol, hostname } = new URL(url);
    return protocol === 'https:' || (protocol === 'http:' && isLoopback(hostname));
  } catch {
    return false;
  }
}

/**
 * Whether a domain is an internationalised name in its ASCII form.
 *
 * A browser converts a host with non-ASCII letters into punycode before
 * anything here sees it, so "xn--chse-63d.com" is simply a different site
 * from "chase.com" and never gets its credential. It is still worth saying
 * out loud, because this is exactly the case where a page looks right and is
 * not.
 */
export function isPunycode(domain) {
  return String(domain ?? '')
    .split('.')
    .some((label) => label.startsWith('xn--'));
}
