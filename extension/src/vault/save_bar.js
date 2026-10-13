// How long the "Save to Ringer Vault?" bar is owed to the user.
//
// A sign-in usually moves to another page straight away, often through a
// redirect or two, and the bar goes with the page it was drawn on. It used
// to be offered again only within 5 seconds of first showing, so a slow
// redirect left the user a bar that flashed and was gone.
//
// Now the bar comes back on each new page until it has been in front of the
// user for 5 seconds in all. The page showing it reports, once a second,
// that it is still on screen in a tab that is in front; only that time
// counts. Once owed nothing more, the bar on screen stays until it is
// answered or closed with its close button, and later pages do not bring it
// back. The login itself still waits no longer than PENDING_MINUTES.

/** On-screen time the bar is owed, across pages. */
export const SAVE_BAR_VISIBLE_MS = 5000;

/** How often, and at most how much, a page reports the bar as seen. */
export const SAVE_BAR_TICK_MS = 1000;

/** Whether a page that has just loaded should show the bar for [pending]. */
export function saveBarDue(pending) {
  return (pending?.seenMs ?? 0) < SAVE_BAR_VISIBLE_MS;
}

/**
 * [pending] after a page reports the bar on screen for [ms] more. Each
 * report counts for one tick at most, whatever it claims.
 */
export function withSaveBarSeen(pending, ms) {
  const step = Math.max(0, Math.min(SAVE_BAR_TICK_MS, Number(ms) || 0));
  return {
    ...pending,
    seenMs: Math.min(SAVE_BAR_VISIBLE_MS, (pending.seenMs ?? 0) + step),
  };
}

/**
 * Whether to offer updating an entry's password yet.
 *
 * A changed password is only worth saving once the site has accepted it:
 * offering "Update?" after a mistyped password, or a stale one some other
 * manager filled, would put the wrong password in the vault. So:
 *
 *  - a new password for a new entry is offered as before ("show");
 *  - an update waits for the sign-in to be seen succeeding: a page with no
 *    password box on it ("show");
 *  - a new page that shows a password box again is the sign-in coming back
 *    with an error, and the update is dropped ("discard");
 *  - the same page, its password box still there, has not answered yet
 *    ("wait": asked again shortly, and decided on the next page otherwise).
 */
export function updateVerdict({ action, newPage, passwordBoxShown }) {
  if (action !== 'update' || !passwordBoxShown) return 'show';
  return newPage ? 'discard' : 'wait';
}
