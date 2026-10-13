// Which accounts the vault already holds, so that with the vault locked a
// login it already has is not offered for saving again.
//
// Only keyed tags are kept: HMAC-SHA256 of the site and the username, under
// a random key kept beside them, cut to 16 bytes. No password is ever part
// of a tag (a tag of one would let anyone with this browser's storage test
// guesses at it). Someone with that storage and a list of sites and email
// addresses could test which sites have an account; the browser's own
// history, in the same profile, already says which sites were visited.

import { registrableDomain } from './host.js';

const encoder = new TextEncoder();

const toBase64 = (bytes) => btoa(String.fromCharCode(...bytes));

async function hmacKey(keyBytes) {
  return crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}

/** The tag for [username] on [site] (a registrable domain). */
export async function knownTag(keyBytes, site, username) {
  const key = await hmacKey(keyBytes);
  const mac = new Uint8Array(await crypto.subtle.sign(
    'HMAC', key, encoder.encode(`${site}\n${String(username ?? '').trim().toLowerCase()}`),
  ));
  return toBase64(mac.slice(0, 16));
}

/** Every site and username pair [entries] are saved for, as tags. */
export async function knownTags(entries, keyBytes) {
  const tags = new Set();
  for (const entry of entries) {
    const users = [entry.username, entry.email].filter((u) => typeof u === 'string' && u.trim() !== '');
    if (users.length === 0) users.push('');
    for (const target of entry.autofillTargets ?? []) {
      if (!target.startsWith('site:')) continue;
      const site = registrableDomain(target.slice('site:'.length)).registrable;
      if (site === null) continue;
      for (const user of users) tags.add(await knownTag(keyBytes, site, user));
    }
  }
  return [...tags];
}
