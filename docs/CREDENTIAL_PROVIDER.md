# Credential Manager provider (Android 14 and later)

Ringer Vault fills logins on Android in two ways. This page says how the
second one, the Credential Manager provider, works beside the first, and
which rules both keep.

1. **Autofill service** (Android 8 and later). Android asks it when a login
   box gets focus, in apps and, with Chrome's "Autofill using another
   service", in Chrome. Its rows appear in the dropdown under the box.
2. **Credential Manager provider** (Android 14 and later). Android asks it
   when an app or a web page asks for a saved credential through Credential
   Manager: the bottom sheet that says "Use saved password or passkey?". Chrome
   shows that sheet on sign-in pages that ask for passkeys (Amazon, Google and
   others), and apps that use Credential Manager show it from their sign-in
   button. Its rows appear in that sheet, beside other providers'.

Passwords only. The provider declares the password capability and no other;
it never answers a passkey request, and it is not a passkey store.

## Coexistence: never the same login twice at once

The two are separate surfaces, shown at different moments: the sheet is
modal, and the dropdown appears on a box that has focus. The rules that keep
them from offering the same login at the same time:

- **While the vault is locked**, neither lists a login. The dropdown shows
  "Unlock Ringer Vault"; the sheet shows the provider's unlock action. A
  locked vault has nothing to list, and no title or username is ever kept
  outside it to list from.
- **After an unlock**, the login is chosen inside Ringer Vault's own screen,
  which then returns one login to the surface that asked: a dataset to the
  dropdown, or one entry to the sheet. The other surface never receives it.
  The vault locks again as the login is handed over (one unlock, one fill).
- **The second page of a sign-in** (the login kept for the password page,
  `NextStep`) is offered by the autofill dropdown only, never by the sheet.
  A fill through the sheet keeps it for the dropdown on the next page, the
  same as a fill through the dropdown.

On Android 14 and later the user may enable Ringer Vault in both places
(Settings, Passwords, passkeys and accounts). Settings > Autofill in the app
shows whether each is on and opens the system screen for each.

## Android 13 and below

There is no third-party Credential Manager provider before Android 14: the
system has no such service to bind. The provider is declared for API 34 and
up only; on older phones it does not exist, and the sheet (where shown, by
Google Play services) lists only Google's own passwords. The autofill
service works as before, and Settings > Autofill shows no provider row.

## Who is asking: caller and origin verification

The same rules as the autofill service (`RequestIdentity`, `BrowserAllowlist`,
`AutofillRequest.fromPlatform`):

- **The caller** is identified by Android, not by anything it says: its
  package name and the SHA-256 of its signing certificate, from the
  `CallingAppInfo` the system passes. A caller signed by more than one
  certificate, or whose certificate cannot be read, is refused.
- **A web address (origin)** is believed only from a browser verified by its
  signing certificate: `CallingAppInfo.getOrigin` with a privileged-apps list
  built from `BrowserAllowlist` (today Chrome Stable, by Google's release
  certificate). Android gives the origin only to callers on that list.
- **A browser that is not verified** (on the list without a known
  certificate, or any app that opens ordinary web links) gets nothing: its
  addresses cannot be trusted, and treating it as an app would pin a browser.
- **Any other app** is treated as that app, whatever page it shows. An app
  that signs in through a web page inside it gets the app's own logins, never
  the address it may report. This is the same rule the autofill service
  follows.

## Every gate, in the real vault and in the decoy

The provider has no screens of its own for unlocking or choosing. Its unlock
action opens the same screen as the autofill row (`AutofillUnlockActivity`,
the Dart autofill screen), so every rule there applies unchanged:

| Gate | Real vault | Decoy |
|---|---|---|
| Unlock on every fill | PIN, password or fingerprint | Decoy PIN |
| Fingerprint offered | Only after the real PIN this run, never after the decoy | Never |
| Which logins | Linked to this app or site, then suggestions | Same rules, decoy's entries |
| Red and amber warnings | Look-alike sites and apps, unverified pins, new sites | Same |
| "Despite warning" in the Security Log | Kept 180 days, in the real vault | Kept in the decoy's own log |
| Saving a new login | No unlock: into the inbox, taken in by the next vault to open | The same: the decoy takes its own copy |
| Sync after a save | As configured | Never |

A login chosen in that screen goes back to the sheet as a single entry. Its
password waits in the app's memory under a random one-time token (never in
the intent), for at most two minutes, and is handed over only to the same
caller (package, certificate and, for a browser, origin) that asked.

## Saving through the sheet

Apps that save a password with Credential Manager's "create password"
request get a "Save to Ringer Vault" entry. It opens the same save screen
as the autofill save prompt, with the same warnings and no unlock: the login
goes into the save inbox (docs/FORMATS.md, section 9) and joins the vault at
its next unlock.

## What is never logged

No title, username, password, PIN, site address or package name is written to
the system log by the provider, as for the autofill service. Release builds
also strip debug logging (`proguard-rules.pro`).
