// Saving a login typed into a web page.
//
// Two steps, both pure, so every rule here is tested without a browser:
//
//   planSave  looks at the unlocked vault and decides: nothing to do (the
//             password is already saved), update an existing entry (same
//             account, new password), or a new entry.
//   applySave makes that change to the decrypted sync file.
//
// The sync file is the phone's, and the phone reads every field of every
// entry. An update therefore edits the entry as stored in the file, keeping
// fields this extension never shows (PINs, a second password, notes), rather
// than rebuilding it from the trimmed copy used for filling.

import { candidatesFor } from './match.js';
import { hostOf } from './host.js';
import { SYNC_FORMAT, SYNC_VERSION } from './format.js';

export const SaveAction = {
  /** This exact password is already saved for this account. */
  none: 'none',
  update: 'update',
  create: 'create',
};

const sameUser = (a, b) =>
  a !== '' && b !== '' && a.trim().toLowerCase() === b.trim().toLowerCase();

/**
 * What saving [login] would do, given the unlocked [entries].
 *
 * Only entries already linked to this site are considered for an update. A
 * login is never written into an entry for another site because its name
 * looks similar; that would be the extension guessing.
 */
export function planSave(entries, { url, username, password }) {
  const { matched } = candidatesFor(entries, url);
  const typed = username ?? '';

  const account = matched.find(
    (c) => sameUser(c.entry.username, typed) || sameUser(c.entry.email, typed),
  )
    // No username on the form, and only one entry for this site: it can
    // only be that one.
    ?? (typed === '' && matched.length === 1 ? matched[0] : undefined);

  if (account === undefined) {
    return { action: SaveAction.create, title: titleFor(url) };
  }
  if (account.entry.password === password) {
    return { action: SaveAction.none, entryId: account.entry.id, title: account.entry.title };
  }
  return { action: SaveAction.update, entryId: account.entry.id, title: account.entry.title };
}

/**
 * Splits a site's logins by whether they belong to [typed], the username or
 * email address already entered (on this page, or on step one of a two-step
 * sign-in). Matching ignores case and surrounding spaces, against either
 * the entry's username or its email. With nothing typed, everything is
 * "others".
 */
export function splitByTypedUser(candidates, typed) {
  const who = (typed ?? '').trim();
  if (who === '') return { mine: [], others: candidates };
  const mine = [];
  const others = [];
  for (const c of candidates) {
    const e = c.entry ?? c;
    (sameUser(e.username ?? '', who) || sameUser(e.email ?? '', who) ? mine : others).push(c);
  }
  return { mine, others };
}

/**
 * A name for a new entry: "Amazon" for www.amazon.in. The same rule as the
 * app's save screen.
 */
export function titleFor(url) {
  const host = hostOf(url);
  if (!host.isUsable) return 'Website';
  const word = host.registrable.split('.')[0];
  return word.charAt(0).toUpperCase() + word.slice(1);
}

/**
 * The site target a saved login is linked to, or null.
 *
 * Nothing is linked from a plain-http page: anyone on the network could have
 * altered it, and linking would let that page vouch for itself next time.
 * The login is still saved; it is linked the first time it is filled
 * somewhere secure.
 */
export function siteTargetFor(url) {
  let scheme = null;
  try {
    scheme = new URL(url).protocol.replace(':', '');
  } catch {
    return null;
  }
  if (scheme !== 'https') return null;
  const host = hostOf(url);
  return host.isUsable ? `site:${host.host}` : null;
}

const isEmail = (value) => value.includes('@');

/** How many earlier passwords an entry keeps. */
export const PASSWORD_HISTORY_LENGTH = 5;

/**
 * [history] with [old] in front, replaced [at]: newest first, no repeats,
 * PASSWORD_HISTORY_LENGTH at most. The same rule as the app's
 * withPreviousPassword (lib/models/vault_entry.dart), kept inside the
 * encrypted sync file with the entry and never put in the copy used for
 * filling (format.js normaliseEntry).
 */
export function withPreviousPassword(history, old, at, current = null) {
  // Not the old one twice, and not the one now in use: going back to an
  // earlier password takes it out of the history.
  const earlier = Array.isArray(history)
    ? history.filter((p) => p && typeof p.password === 'string' && p.password !== ''
      && p.password !== old && p.password !== current)
    : [];
  return [{ password: old, replacedAt: at }, ...earlier].slice(0, PASSWORD_HISTORY_LENGTH);
}

/**
 * The time to stamp a change made here with: [now], unless the sync file
 * already holds something stamped later (a device whose clock runs ahead),
 * in which case one millisecond after it.
 *
 * Sync keeps the later of two versions of an entry, so without this a
 * browser whose clock runs behind lost changes it made after seeing
 * another device's edit. The same hybrid logical clock as the app's
 * StorageService.nextStamp.
 */
export function nextStamp(records, now = new Date()) {
  let known = null;
  for (const r of records) {
    const at = Date.parse(r?.updatedAt ?? '');
    if (!Number.isNaN(at) && (known === null || at > known)) known = at;
  }
  if (known === null || known < now.getTime()) return now.toISOString();
  return new Date(known + 1).toISOString();
}

/**
 * Returns a new sync file with the login saved.
 *
 * [parsed] is the decrypted file as the app wrote it. [plan] comes from
 * {@link planSave}; when it named an entry that has since been deleted on
 * another device, the login is saved as a new entry instead.
 */
export function applySave(parsed, plan, login, { now = new Date(), newId = () => crypto.randomUUID() } = {}) {
  if (!parsed || parsed.format !== SYNC_FORMAT || !Array.isArray(parsed.records)) {
    throw new Error('Only the Drive sync file can be saved to.');
  }
  if (typeof parsed.version !== 'number' || parsed.version > SYNC_VERSION) {
    throw new Error('The synced vault was written by a newer version of Ringer Vault.');
  }

  const at = nextStamp(parsed.records, now);
  const target = siteTargetFor(login.url);
  const typed = (login.username ?? '').trim();
  const records = parsed.records.map((r) => r);

  const index = plan.entryId === undefined
    ? -1
    : records.findIndex((r) => r?.id === plan.entryId && r.deleted !== true && r.entry);

  if (plan.action === SaveAction.update && index >= 0) {
    const entry = { ...records[index].entry };
    if (typeof entry.password === 'string' && entry.password !== '' && entry.password !== login.password) {
      entry.passwordHistory = withPreviousPassword(entry.passwordHistory, entry.password, at, login.password);
    }
    entry.password = login.password;
    entry.updatedAt = at;
    if (!entry.username && !entry.email && typed !== '') {
      if (isEmail(typed)) entry.email = typed;
      else entry.username = typed;
    }
    const targets = Array.isArray(entry.autofillTargets) ? [...entry.autofillTargets] : [];
    if (target !== null && !targets.includes(target)) targets.push(target);
    entry.autofillTargets = targets;
    records[index] = { id: entry.id, updatedAt: at, entry };
  } else {
    const id = newId();
    records.push({
      id,
      updatedAt: at,
      // Every field the app's VaultEntry.fromJson reads, so the phone takes
      // it exactly like an entry it wrote itself.
      entry: {
        id,
        title: plan.title || titleFor(login.url),
        username: isEmail(typed) ? '' : typed,
        password: login.password,
        category: 'Social',
        email: isEmail(typed) ? typed : '',
        pin: '',
        notes: null,
        passwordLabel: '',
        extraPassword: '',
        extraPasswordLabel: '',
        pinLabel: '',
        extraPin: '',
        extraPinLabel: '',
        autofillTargets: target === null ? [] : [target],
        createdAt: at,
        updatedAt: at,
      },
    });
  }

  return {
    ...parsed,
    writtenBy: 'chrome-extension',
    writtenAt: at,
    records,
  };
}

/**
 * Returns a new sync file with [entryId] linked to [url]'s site, after the
 * user chose to fill it there although it was not linked yet. Null when
 * there is nothing to change: the entry is gone, it is linked already, or
 * the page is plain http (never linked; see {@link siteTargetFor}).
 */
export function applyLink(parsed, entryId, url, { now = new Date() } = {}) {
  if (!parsed || parsed.format !== SYNC_FORMAT || !Array.isArray(parsed.records)) {
    throw new Error('Only the Drive sync file can be saved to.');
  }
  if (typeof parsed.version !== 'number' || parsed.version > SYNC_VERSION) {
    throw new Error('The synced vault was written by a newer version of Ringer Vault.');
  }
  const target = siteTargetFor(url);
  if (target === null) return null;
  const index = parsed.records.findIndex((r) => r?.id === entryId && r.deleted !== true && r.entry);
  if (index < 0) return null;
  const targets = Array.isArray(parsed.records[index].entry.autofillTargets)
    ? parsed.records[index].entry.autofillTargets
    : [];
  if (targets.includes(target)) return null;

  const at = nextStamp(parsed.records, now);
  const records = parsed.records.map((r) => r);
  const entry = { ...records[index].entry, autofillTargets: [...targets, target], updatedAt: at };
  records[index] = { id: entry.id, updatedAt: at, entry };
  return { ...parsed, writtenBy: 'chrome-extension', writtenAt: at, records };
}
