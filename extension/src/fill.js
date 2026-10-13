// Injected into the page to put one credential into one form.
//
// Injected on demand, at the moment an entry is picked, into the top frame
// of the tab it was picked for. The page script that offers the list never
// holds a password; only this function, run by the extension itself, does.

/**
 * Runs inside the page. Returns what it did, so the popup can tell the truth
 * about whether anything was filled instead of claiming success blindly.
 */
export function fillCredential({ username, password }) {
  // A box a person can see: not hidden, not see-through (itself or any
  // box around it), not a pixel or two across, and not pushed off the page
  // to the left, top or right. Hidden boxes are where a script on the page
  // could wait to be handed a password.
  const MIN_PX = 8;
  const VISIBLE = (el) => {
    if (el.disabled || el.readOnly) return false;
    const style = window.getComputedStyle(el);
    if (style.visibility !== 'visible' || style.display === 'none') return false;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const s = node === el ? style : window.getComputedStyle(node);
      if (Number(s.opacity) === 0 || s.display === 'none') return false;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width < MIN_PX || rect.height < MIN_PX) return false;
    const left = rect.left + window.scrollX;
    const top = rect.top + window.scrollY;
    const pageWidth = Math.max(document.documentElement.scrollWidth, window.innerWidth);
    return left + rect.width > 0 && top + rect.height > 0 && left < pageWidth;
  };

  const NEVER = /search|query|otp|one-?time|2fa|two-?factor|verification|captcha|cvv|cvc|card|coupon|promo/i;
  const NEW_PASSWORD = /new[-_ ]?password|confirm|repeat|retype/i;
  const USERNAME = /user|email|login|account|identifier|phone/i;

  const describes = (el) =>
    [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
      el.getAttribute('autocomplete')].filter(Boolean).join(' ');

  const inputs = Array.from(document.querySelectorAll('input')).filter(VISIBLE);

  const passwords = inputs.filter(
    (el) => el.type === 'password' && !NEVER.test(describes(el)),
  );
  // A sign-up form asks you to invent a password; filling the old one there
  // is how people lock themselves out of accounts.
  const signUp = passwords.some(
    (el) =>
      NEW_PASSWORD.test(describes(el)) ||
      el.getAttribute('autocomplete') === 'new-password',
  );
  if (signUp) return { filled: [], reason: 'signup' };

  // One form only. The one the person is in, when they are in one;
  // otherwise the form of the first password box. Boxes in any other form
  // are never filled from this pick.
  const focused = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
  const scope = focused?.form ?? null;
  const inScope = (el) => scope === null || el.form === scope;
  const passwordField = passwords.find(inScope) ?? null;
  const form = passwordField?.form ?? scope;

  const looksLikeUsername = (el) =>
    ['text', 'email', 'tel', ''].includes(el.type) &&
    !NEVER.test(describes(el)) &&
    (['username', 'email'].includes(el.getAttribute('autocomplete')) ||
      el.type === 'email' ||
      USERNAME.test(describes(el)));
  // With a password box, its own form's username box, or one before it on
  // a page without forms; without one (a username-only step), the first.
  const usernameField =
    inputs.find(
      (el) =>
        looksLikeUsername(el) &&
        (form !== null
          ? el.form === form
          : passwordField === null ||
            (el.form === null &&
              (el.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0)),
    ) ?? null;

  const set = (el, value) => {
    if (!el || !value) return false;
    // Frameworks track their own state, so assigning .value alone is often
    // reverted on the next render. The native setter plus the events a real
    // keystroke produces is what makes the change stick.
    const proto = Object.getPrototypeOf(el);
    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    if (setter) setter.call(el, value);
    else el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };

  // Chrome's own password manager may fill the same box a moment later
  // with the password it has saved, which can be an old one: the sign-in
  // then fails with what looks like Ringer Vault's password. For a few
  // seconds, a value changed by anything other than the user's own typing
  // is put back. The boxes are also marked, in this extension's own view of
  // the page, so the save bar does not offer to "update" an entry with
  // whatever replaced its password (capture.js).
  const filledBoxes = (window.__ringerFilled ??= new WeakSet());
  // At most this many put-backs per box, so two managers can never fight
  // in a loop; after that the box is left as it is.
  const MAX_RESTORES = 3;
  const keep = (el, value) => {
    filledBoxes.add(el);
    let kept = value;
    let restores = 0;
    let typed = false;
    // The user changing the text in any way: keys, an on-screen keyboard,
    // dictation, a paste or a drop. Only events the browser itself raises
    // (isTrusted): a page script cannot fake one. Autofill raises none.
    // Enter raises a line break, which a one-line box ignores.
    const NOT_TEXT = ['insertLineBreak', 'insertParagraph', 'insertReplacementText'];
    const byUser = (e) => {
      if (e.isTrusted && !NOT_TEXT.includes(e.inputType)) typed = true;
    };
    el.addEventListener('beforeinput', byUser, true);
    const until = Date.now() + 5000;
    const done = () => {
      // The copy of the password goes when the window ends.
      kept = null;
      el.removeEventListener('beforeinput', byUser, true);
    };
    const check = () => {
      if (typed || !el.isConnected || kept === null) return done();
      if (el.value !== kept) {
        if (restores >= MAX_RESTORES) return done();
        restores++;
        set(el, kept);
        // Said in the page, in the extension's own closed bar (capture.js).
        if (el.type === 'password') window.__ringerRestored?.();
      }
      if (Date.now() < until) setTimeout(check, 200);
      else done();
    };
    setTimeout(check, 200);
  };

  const filled = [];
  if (set(usernameField, username)) {
    filled.push('username');
    keep(usernameField, username);
  }
  if (set(passwordField, password)) {
    filled.push('password');
    keep(passwordField, password);
  }

  if (filled.length === 0) return { filled: [], reason: 'no-fields' };
  return { filled, reason: null };
}
