# Threat model

What Ringer Vault defends against, how, and where it stops. **Ringer Vault has
not been independently audited.** This is the design as written and tested by
its developer.

## What is protected

- The entries in each vault: usernames, passwords, PINs, notes, and which
  sites and apps they are linked to.
- Whether a decoy vault exists.
- The synced copy in Google Drive and any exported backup.
- Which sites the user visits, beyond the few lookups listed in the privacy
  policy.

## Who it is protected from, and how

| Threat | Defence | Where |
|---|---|---|
| A lost or stolen phone, locked | Every vault is encrypted under a key sealed by Argon2id of the secret; lockouts that grow to an hour and survive waiting, restarts and clock changes, and optional self-destruct, on wrong guesses | VaultKeyService, AuthService |
| A copy of the vault file taken off the phone | Argon2id (32 MiB) per guess; a password rather than a PIN puts it out of reach; the setup makes a password the default | FORMATS.md, setup screen |
| Someone forcing the user to unlock | A decoy PIN opens a second, believable vault; nothing readable without the real vault's key says a decoy exists; unlocks take the same time; the fingerprint opens the real vault only, and only after its PIN this run | decoy tests, timing test |
| A file put back from earlier (rollback) | Sealed write counters per vault; recovery from the kept copy only when exactly one write behind | vault_container.dart |
| A crash mid-save | Whole-file writes with the previous copy kept | vault_crash_test.dart |
| Google, or anyone with the Drive file | Encrypted before upload with the sync passphrase (Argon2id 64 MiB); weak passphrases refused | sealed_file.dart, passphrase_strength.dart |
| An older Drive copy put back | A generation counter inside the encryption; a device refuses a copy older than one it has accepted | sync_payload.dart, rollback.js |
| A look-alike website | Logins fill only on the exact site they are linked to; look-alikes of vault sites are warned about in red; "fill anyway" is logged for 180 days | lookalike.dart, lookalike.js |
| A fake app with a bank's name | Apps identified by signing certificate, pinned on first fill; the site is asked whether the app is its own (Digital Asset Links) | autofill_target.dart, asset_links.dart |
| A browser claiming a site it is not showing | Web addresses believed only from Chrome, verified by its certificate; any other browser gets nothing | BrowserAllowlist.kt, CredentialCaller.kt |
| A page script in Chrome | The extension's list and bar live in closed shadow roots, act only on real clicks, and the page cannot message the extension; typing is told from filling by browser-raised events only | capture.js, fill.js |
| Another password manager filling a stale password over Ringer Vault's | Ringer Vault puts its fill back (at most three times, five seconds), and never offers to "update" an entry with what replaced it | fill.js |
| Saving a mistyped password over a good one | An update is offered only once the sign-in is seen to succeed | save_bar.js |
| A login saved while the vault is locked | Sealed to the vault's public key (X25519, AES-256-GCM); only the vault's private key, inside the vault, opens it; copies for both vaults, so nothing says whether a decoy exists | save_inbox.dart |
| Leaks to the system log | No titles, usernames, passwords, PINs or site addresses are logged; release builds strip debug logging; checked with logcat on a real phone | proguard-rules.pro |

## Honest limits

- **Not audited.**
- **Root, or malware running as the app,** can read what the app reads while
  it is unlocked. Ringer Vault protects data at rest and in transit.
- **Someone who has the real PIN** has the real vault.
- **Rollback protection rests on the write counters** in Android's secure
  storage. A missing or unreadable counter reads as none, so someone able
  to change the app's private storage (in practice, root) could remove it
  together with putting back an older file. Treating a missing counter as
  tampering would lock people out after a keystore fault, so it is not.
- **Saving needs no unlock:** someone holding the phone unlocked can add
  logins, or replace a saved password (the old one stays in its history).
  Look-alikes of the vault's own sites are named at the next unlock, not on
  the save sheet. A vault always takes its own waiting logins, however long
  it stays locked; one that only looks like an existing entry is asked
  about at the unlock rather than written over it.
- **The extension's account list** (keyed tags of site and username, no
  passwords) lets someone with the Chrome profile test whether an account
  exists on a site; it exists so a locked vault does not ask to save a login
  it already has.
- **The fingerprint is not a secret.** Under coercion, keep it off.
- **A new device trusts the first copy it sees** in Drive: it has no earlier
  generation to compare with.
- **The decoy's Settings**: whatever would reach the real vault (sync,
  removing data, self-destruct, turning the fingerprint on, setting up a
  decoy) gives an ordinary failure in the decoy. Someone who tries those may
  notice they never succeed.
- **Timing** of the three kinds of unlock matches to within a few percent on
  the phones measured, not exactly.
- **The device's security log is kept in Hive,** which is no longer actively
  maintained. It holds no vault contents. Replacing it is planned.
- **Two-minute exception** to "every fill is unlocked for": the password page
  right after a fill from an entry is offered that entry with one tap, on the
  same site or app only, dropped on any lock and when the decoy opens.
- **Sizes**: the vault file's slots are padded to size buckets; the Drive
  file and backups are not, so their size says roughly how much they hold.
- **Backups** are versioned sealed files (Argon2id on the phone), but the
  entry list inside them carries no schema version of its own (FORMATS.md).
- **Strict Offline Mode** is the app's own rule: Android grants the internet
  permission at install.
- **The web build** writes the older PBKDF2-based sync format.
- **Chrome's own password manager** can still fill in Chrome alongside
  Ringer Vault until its saved passwords are deleted; the extension says how.
