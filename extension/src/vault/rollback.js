// Telling an older copy of the sync file, put back in Drive, from the
// current one.
//
// Every write numbers the file one above the copy it replaced (its
// `generation`, inside the encryption, so nobody without the passphrase can
// raise it), and each browser remembers the highest it has accepted. A copy
// below that is refused. The same rules as generationStep in the app's
// lib/sync/sync_engine.dart; test/fixtures/rollback_cases.json holds the
// cases both must agree on.
//
// Storage is passed in ({ get(): Promise<number>, set(n): Promise }), so
// these can be tested without Chrome.

import { generationOf, RolledBackError, SYNC_VERSION } from './format.js';

/**
 * What to do with a copy of generation [found], having accepted [seen]:
 * null to refuse it, otherwise the generation to write next.
 */
export function generationStep({ found, seen, acceptOlder = false }) {
  if (found < seen && !acceptOlder) return null;
  return Math.max(found, seen) + 1;
}

/** Throws RolledBackError for an older copy; otherwise remembers [parsed]'s. */
export async function acceptCopy(parsed, store) {
  const found = generationOf(parsed);
  const seen = await store.get();
  if (generationStep({ found, seen }) === null) throw new RolledBackError(found, seen);
  if (found > seen) await store.set(found);
}

/**
 * Takes [parsed] as it is, older or not, and remembers it: what connecting
 * with the passphrase does, which is also how a copy restored on purpose is
 * accepted.
 */
export async function adoptCopy(parsed, store) {
  await store.set(generationOf(parsed));
}

/** [file], to replace [parsed], numbered above everything seen. */
export async function nextCopy(file, parsed, store) {
  const generation = generationStep({ found: generationOf(parsed), seen: await store.get(), acceptOlder: true });
  return { ...file, version: SYNC_VERSION, generation };
}
