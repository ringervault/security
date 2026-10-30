# The subscription

Ringer Vault is free for up to 20 logins. A monthly subscription, bought in
the Android app through Google Play, lifts the limit and adds sync between
devices. There is no account with us and no server of ours: Google Play is
where it is bought and checked.

## What each plan does

| | Free | Subscribed | Subscription ended |
|---|---|---|---|
| Logins | up to 20 per vault | unlimited | everything saved stays |
| See, search, copy, fill, edit, delete, export | yes | yes | yes, always |
| Add a login (by hand, import, autofill, save inbox, extension) | up to 20 | yes | only below 20 |
| Google Drive sync between devices | no | yes | paused; nothing deleted on either side |
| Chrome extension | its own vault, up to 20 | the synced vault, unlimited | as free |
| Backup to a file | yes | yes | yes |

Nothing saved is ever held back. A subscription sells room to grow, not
access to what is already there.

## Google Play

- Product `ringervault_premium` ("Ringer Vault Premium"), created in Play
  Console on 26 October 2026 under Monetize with Play, Products,
  Subscriptions. Base plan `monthly`: auto-renewing, ₹99 in India, other
  regions converted by Play, 7-day grace period. Offer `free-trial-7d`:
  7 days free, only for people who never had this subscription. The app
  finds the trial by its free phase, not by these IDs.
- License testing (Play Console, Manage account): the list "Ringer Vault
  testers" buys without being charged.
- Google's reviewers reach Premium through one-time Play promo codes (the
  promotion "Google Play app review", 30 days free), named in the Sign in
  details declaration. The codes are kept out of this repository. A code
  redeemed in the Play Store reaches the app at its next start or return to
  the front, when it asks Play what is active.
- The app uses `in_app_purchase` (Google Play Billing). It asks Play what is
  active when it starts and whenever it comes to the front, but not in
  Strict Offline Mode. New purchases are acknowledged at once, as Play
  refunds one left unacknowledged for three days.
- "Restore purchase" asks Play again; a subscription belongs to the Google
  account on the phone, not to a vault.

## Redeem codes

Settings, and the subscription sheet, have **Redeem a code**. One box takes
two kinds:

- **Google Play promo codes** (letters and numbers, made in Play Console
  under the subscription's promotions; 3 to 90 days). Google gives apps no
  way to redeem these themselves, so the app opens the Play Store's own
  redeem screen with the code filled in. The app sees the subscription when
  it next comes to the front.
- **Ringer Vault's own codes** (starting `RV-`, about 107 characters, meant
  to be pasted): a day, a week, a month, a year or a lifetime of Premium,
  or a cancel code, which stops Premium from codes there and then. Checked
  on the phone, offline, by their Ed25519 signature (FORMATS.md, section
  10). Each works once per phone. One redeemed while another runs adds on
  after it. They are kept on the phone, and once sync is on (then or later)
  in the sync file, so the extension counts them too and another device of
  the same vault cannot use the same code again.

Make them with `node tool/codes/make_codes.mjs --plan week --redeem-by
2026-12-31 --count 5`. The signing key stays on the computer that makes
codes; it is in no repository.

Own codes are given away, never sold: Google Play's rules require its own
billing for anything paid. With no server, a code cannot be stopped from
working on several phones that do not share a vault, and a cancel code works
only where it is redeemed. Give codes to people rather than posting them.

## How long an answer is believed

Each time Play says the subscription is active, the phone records the time
(`confirmedAt`). Without a newer answer it is believed for 35 days after that:
a month of billing and a few days to spare, so a subscriber who is offline,
or in Strict Offline Mode, is not cut off early. When Play answers that there
is no subscription, it ends at once. The time used never runs backward:
the latest time seen is kept, so turning the clock back does not stretch a
subscription that has run out.

## The extension

The extension cannot ask Google Play. The phone writes Play's signed purchase
record into the encrypted sync file (FORMATS.md, section 5), and the extension
checks Google's RSA signature on it with the app's public licensing key
(`PLAY_LICENSE_KEY` in `extension/src/vault/plan.js`, from Play Console,
Monetization setup, Licensing; set 25 October 2026). The key is public by
design: it can check Google's signatures but never make one.

Someone using only the extension (no Android phone) gets a free vault of 20
in Chrome. Nothing is sold in Chrome; the subscription is bought in the app.

## The decoy vault

The subscription belongs to the phone, so both vaults follow the same
answer, and each counts its own logins. The decoy's believable sample
logins are cut to 20 on a phone without a subscription, so a decoy always
looks like a free vault could.

## Limits of a check on the device

The limit is enforced in the app and the extension. Someone who rebuilds
either from source can remove it, as with any app that has no server. The
encryption is unaffected. Play's automatic protection (an installer check
Google adds to the Play build) and Google's signature on the purchase stop
the simple cases.

## Where it lives

| | |
|---|---|
| Free plan rules | `lib/subscription/plan.dart`, `extension/src/vault/plan.js` |
| What Play said, and how long it holds | `lib/subscription/entitlement.dart` |
| The extension's signature check | `extension/src/vault/plan.js` (`verifyPurchase`, `subscriptionIn`) |
| Redeem codes | `lib/subscription/redeem_code.dart`, `extension/src/vault/codes.js`, `tool/codes/make_codes.mjs`; format in `docs/FORMATS.md`, section 10 |
| Tests | `extension/test/plan.test.mjs`, `extension/test/codes.test.mjs`, `test/redeem_code_cases_test.dart` (both run `test/fixtures/code_cases.json`) |

The app's Google Play code, its screens, and the place every way of adding
a login checks the limit are not part of this repository.
