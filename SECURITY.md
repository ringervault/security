# Security

Ringer Vault is a password manager for Android, with a companion browser
extension. This page says what protects your passwords, what does not, and
how to report a problem.

**Ringer Vault has not been independently audited.** Everything below is the
design as written and tested by its developer. Treat it accordingly.

## Reporting a vulnerability

Email **ringervault@gmail.com** with "Security" in the subject. Please
include what you found and how to reproduce it, and give a reasonable time
to fix it before telling anyone else. There is no bug bounty.

For anything that is not a security problem, use the issue tracker or
Settings > Send feedback in the app.

## What protects your passwords

**On the phone.** Both vaults (the real one and the decoy) live in one file,
`vault.rvc`. Each vault is one AES-256-GCM encrypted slot in it, under a
random 256-bit key of its own. That key is sealed with a key derived from
your PIN or password by Argon2id (32 MiB, 3 passes), and the sealed copy is
kept in Android's keystore-backed storage. A changed byte, a removed entry,
or an older copy of the file put back is detected, and the vault is not
opened as if it were whole. The file is written by replacing it whole, with
the previous version kept, so a crash during a save loses at most that save.

**The decoy.** A second PIN opens a second vault in the same file. The file
is the same size with or without a decoy, the decoy's key records exist on
every phone (random stand-ins when there is no decoy), every unlock runs the
same key derivations whichever PIN is typed, and nothing readable without
the real vault's key says whether a decoy exists. Tests check each of these.

**Google Drive sync (optional).** The copy in Drive is encrypted on the
phone before upload with a key derived from your sync passphrase by Argon2id
(64 MiB, 3 passes). Google holds ciphertext only. Because a copy of that file
can be taken away and guessed at offline, the sync passphrase must be hard
to guess: common words, names, years and keyboard patterns count for little,
and a passphrase estimated below 50 bits is refused. Each copy carries a
counter inside its encryption, so a device refuses an older copy put back in
Drive.

**Autofill.** A password is offered only to the app or website it is linked
to: an app by its package and signing certificate, a website by its exact
address. Every fill is unlocked for, with one exception: on a two-step
sign-in, the password page right after a fill from an entry is offered that
entry's password with one tap and no second unlock, for two minutes, in the
same app or on the same site (the same address, with or without "www.") in a
verified browser, and not once the vault has locked or the decoy has been
opened. When exactly one login is linked to the app or site and nothing
warrants a warning, it is filled straight after the unlock, without a list
to choose from. Look-alike websites and apps a site does not vouch for are
warned about in red, and filling anyway is recorded in the Security Log.

**Credential Manager** (Android 14 and later). Passwords also appear in the
system's sign-in sheet, by the same rules as autofill: the same unlock on
every fill, the same caller checks (an app by its certificate, a web address
only from a browser verified by its certificate), the same warnings and log.
Passwords only, never passkeys. `docs/CREDENTIAL_PROVIDER.md` says how the
sheet and the autofill dropdown never offer the same login at once.

**Seeing other apps.** To check the certificate of the app asking, Ringer
Vault sees apps with a launcher icon and apps that open web links
(`<queries>` in the manifest), not every installed app.

**Earlier passwords.** Each entry keeps its last five passwords, inside the
vault's encryption with the entry, shown only after the same check as
revealing its password, and synced with it.

**Wrong attempts.** Unlocking is refused for 30 seconds after the 5th wrong
attempt in a row, 5 minutes after the 10th, 15 after the 15th and an hour
after the 20th; only a correct unlock resets the count, so waiting out each
lockout does not. Lockouts are timed on the time since the phone started,
which changing the date and time does not move, and run again in full after
a restart. Self-destruct, when armed, counts the same attempts.

**Fingerprint.** The fingerprint opens the real vault only, and is offered
only after the real vault's PIN has been entered in the current run of the
app, never after the decoy.

The details are in `docs/ARCHITECTURE.md`, `docs/FORMATS.md` (byte-level
formats), `docs/THREAT_MODEL.md`, `docs/SYNC.md`, `extension/README.md`, and
the comments of the files they name.

**Saving without an unlock.** A login typed into an app or website can be
saved with no PIN or fingerprint. It is not written into the vault, which
stays locked: it is encrypted to the vault's public key (X25519 and
AES-256-GCM, a key that can lock but not open) and waits in a file of its
own until the next unlock, which adds it. The private key is inside the
vault. Copies are made for both vaults, so the decoy receives saves too and
the files say nothing about whether a decoy exists (docs/FORMATS.md,
section 9). At the unlock, a new password for an account already linked to
that app or site replaces the old one (kept under Previous passwords); one
that only looks like an existing entry is asked about, and nothing is
changed or linked until it is answered.

**The decoy's contents** are drawn afresh for every decoy: which of about 50
services, which bank and which of its PINs, the owner's password habits
(from many patterns and word lists), notes and dates. The generator is
public, so it has no fixed recipe a decoy could be recognised by, and every
entry can be changed or added to from inside the decoy.

## Known limits

- **Not audited.** See above.
- **Someone with the phone unlocked, or root on it,** can read what the app
  can read. Ringer Vault protects data at rest and across sync; it cannot
  protect a vault from malware running as the app, or from someone who has
  the PIN.
- **Saving needs no unlock,** so anyone holding the phone unlocked can add
  logins to the vault (not read any). A changed password for an account
  already linked to that app or site replaces it at the next unlock, with
  the old one kept under "Previous passwords"; anything less certain is
  asked about first. The comparison with the vault's own sites (for
  look-alikes) happens at that unlock rather than on the save sheet, which
  can only compare with well-known brands. With "Check how new a site is"
  on, the site of every login saved this way is checked, linked or not,
  since the vault cannot be read to tell.
- **The Chrome extension remembers which accounts exist** (site and
  username, as keyed tags, never passwords) so that a locked vault does not
  ask to save a login it already has. Someone with access to the Chrome
  profile, and a list of sites and email addresses to try, could test which
  sites have an account; the same profile's browsing history already shows
  which sites were visited.
- **The fingerprint is not a secret.** Anyone who can make you touch the
  sensor can open the real vault, where the fingerprint is on. Under that
  kind of threat, use the PIN only.
- **A new device trusts the first copy it sees.** A device remembers the
  newest Drive copy it has accepted and refuses an older one, but a device
  syncing for the first time has nothing to compare with.
- **Some of the decoy's settings cannot work.** In the decoy, entries,
  categories, its own PIN, export and import (into the decoy), the Security
  Log, auto-lock, panic shake and the other phone-wide switches work as in
  the real vault. What would reach the real vault cannot: sync answers as a
  Google sign-in that did not complete (and contacts nobody); removing data
  from the phone, self-destruct, turning the fingerprint on and setting up a
  decoy answer with an ordinary "try again later" failure. Someone who tries
  those may notice they never succeed.
- **Timing.** Unlocks with the real PIN, the decoy PIN, and a wrong PIN take
  the same time to within a few percent on the phones it has been measured
  on (see `integration_test/unlock_timing_test.dart`), not exactly the same.
- **The web build of the app** writes Drive copies in an older, PBKDF2-based
  format and refuses to write over a newer one.
- **Strict Offline Mode** is enforced by the app's own code: the app holds
  the internet permission, which Android grants at install.

## Third-party code on the encryption path

- **cryptography** (Dart): AES-GCM and Argon2id in the app.
- **hash-wasm 4.12.0** (MIT): Argon2id in the extension, vendored at a
  pinned version whose SHA-256 a test checks. Shared test vectors make the
  app and the extension prove they derive the same keys.
- **Hive** (Dart): no longer holds the vault. It still holds the device's
  security log, and is used once to read vaults written by older versions.
  Hive is not actively maintained; replacing it for the security log is
  planned after the first public release.

## Network connections

Listed in the privacy policy: Google Drive sync when
it is on, a website's own app list before a first autofill into an app, and
the optional new-site check. None goes to a server of ours, and Strict
Offline Mode stops all of them.
