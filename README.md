# Ringer Vault: security code

Ringer Vault is a password manager for Android with a companion Chrome
extension. This repository publishes the parts that protect your data, with
their tests, so that anyone can check what the app and the extension
actually do instead of taking our word for it.

**Ringer Vault has not been independently audited.** This code and these
documents are the design as written and tested by its developer.

It matches Android app **1.0.0** and Chrome extension **0.3.9**.

## What is here

| Folder | What it holds |
|---|---|
| `lib/services/` | The vault file (`vault_container.dart`), each vault's keys (`vault_key_service.dart`), opening and writing vaults (`storage_service.dart`), unlocking, lockout, the decoy and self-destruct (`auth_service.dart`), saving without an unlock (`save_inbox.dart`) |
| `lib/utils/` | The sealed-file format used for sync and backups (`sealed_file.dart`), passphrase and PIN strength |
| `lib/sync/` | Sync: encryption, merging, rollback protection (Google sign-in and Drive access are not included) |
| `lib/autofill/` | Who is asking for a password, look-alike sites, a website's own app list, the new-site check |
| `lib/models/`, `lib/repository/` | The entry format, and the layer the screens use |
| `android/` | The Android autofill service and the Credential Manager provider (Kotlin), with their unit tests. For reading: they need the rest of the app to build |
| `extension/` | The Chrome extension's security modules (encryption, quick unlock, rollback, matching, look-alikes, saving rules), with their tests |
| `lib/subscription/` | The free plan's rule, and how long Google Play's word on a subscription is believed (the Play code itself is not included) |
| `docs/` | Architecture, threat model, byte-level formats, sync, the sign-in sheet design, the subscription, dependencies |
| `test/` | The Dart tests for all of the above, and shared test vectors |
| `integration_test/` | The on-device check that every unlock takes the same time, whichever vault opens |

This is for reading and testing, not for running. Neither the app nor the
extension can be built from here: the app's screens, its Android build,
signing and Google sign-in are not included, and neither are the
extension's manifest, background worker, page script, pop-up and Drive
access. Install Ringer Vault from Google Play and the Chrome Web Store.

The documents describe the whole product, so some files they name are not
in this repository.

## Check it yourself

Dart (Flutter 3.44 or later):

```bash
flutter pub get
flutter test
```

Chrome extension (Node 20 or later):

```bash
cd extension
npm test
```

The unlock timing check needs a phone or emulator:

```bash
flutter test integration_test/unlock_timing_test.dart -d <device>
```

At the time of publishing: 601 Dart tests and 225 extension tests, all
passing. `test/extension_interchange_test.dart` runs the extension's own
code from Dart, so the two prove they read and write each other's files.

## Where each claim is backed

| Claim | Code | Tests |
|---|---|---|
| Each vault is AES-256-GCM under its own random key, wrapped with Argon2id of the PIN or password | `vault_container.dart`, `vault_key_service.dart` | `vault_container_test.dart`, `vault_key_service_test.dart` |
| A changed byte, a removed entry or an older copy put back is refused | `vault_container.dart`, `storage_service.dart` | `vault_container_test.dart`, `rollback_cases_test.dart`, `recovery_test.dart` |
| Wrong attempts lock unlocking for longer and longer, and only a correct unlock resets the count; optional self-destruct | `auth_service.dart`, `lockout_clock.dart` | `lockout_test.dart`, `self_destruct_test.dart` |
| A crash during a save loses at most that save | `storage_service.dart` | `vault_crash_test.dart` |
| Nothing readable without the real vault's key says a decoy exists | `vault_container.dart`, `auth_service.dart` | `decoy_traces_test.dart`, `decoy_edits_test.dart` |
| Sync is encrypted on the device with Argon2id (64 MiB) and AES-256-GCM | `sealed_file.dart`, `sync_cipher.dart`, `extension/src/vault/format.js` | `sealed_file_v3_test.dart`, `extension_interchange_test.dart` |
| An older Drive copy put back is refused | `sync_engine.dart`, `extension/src/vault/rollback.js` | `sync_engine_test.dart`, `extension/test/rollback.test.mjs` |
| Weak sync passphrases are refused | `passphrase_strength.dart` | `passphrase_strength_test.dart` |
| A password goes only to the app or site it belongs to | `autofill_target.dart`, `RequestIdentity.kt`, `BrowserAllowlist.kt` | `autofill_matching_test.dart`, `autofill_cases_test.dart`, `CredentialRulesTest.kt` |
| Look-alike sites are named | `lookalike.dart`, `extension/src/vault/lookalike.js` | `lookalike_test.dart` |
| A login saved while locked is sealed to the vault's public key and joins it at the next unlock; one that only looks like an existing entry is asked about, never written over it | `save_inbox.dart` | `save_inbox_test.dart` |
| A decoy has no fixed recipe it could be recognised by | `decoy_seed.dart` | `decoy_seed_test.dart` |
| The extension's quick-unlock PIN is sealed under a key from the vault's own Argon2id derivation | `extension/src/vault/format.js`, `quick.js` | `extension/test/quick.test.mjs`, `format_v3.test.mjs` |
| Only visible boxes in one form are filled | `extension/src/fill.js`, `StructureParser.kt` | `extension/test/fill.page.html` (in a browser), `FieldWordsTest.kt` |
| Generated passphrases are about 71 bits, and the strength meter counts a dictionary word at what it is worth | `password_generator.dart`, `passphrase_strength.dart`, `eff_words.g.dart` | `passphrase_strength_test.dart`, `extension/test/passphrase_strength.test.mjs` |
| A removed write-count record does not switch rollback protection off | `storage_service.dart` | `rollback_counter_test.dart` |
| A key record from a newer version is reported as such, never guessed at | `vault_key_service.dart` | `kdf_unknown_test.dart` |
| Accented passphrases make the same key on every device | `secret_text.dart`, `extension/src/vault/format.js` | `secret_text_test.dart`, `extension/test/unicode_secret.test.mjs` |
| The extension counts a subscription only with Google Play's own signature on it, for this app and product; a subscription that ends never holds saved logins back | `lib/subscription/`, `extension/src/vault/plan.js` | `extension/test/plan.test.mjs` |
| Tests never touch real data | `test/support/render_harness.dart` | `leak_audit_test.dart` |

## Review fixes

Independent reviews of this repository are welcome, and what they find is
fixed here in the open. Each item below came from a review of an earlier
commit.

**First review**
- Waiting out a lockout no longer resets the count of wrong attempts;
  lockouts grow to an hour, and changing the phone's clock or restarting
  does not end one early (`lockout_test.dart`, `self_destruct_test.dart`).
- A login saved while locked that only looks like an existing entry is
  asked about at the unlock, never written over it or linked.
- Decoy contents are drawn afresh for every decoy.
- The extension's quick-unlock PIN is sealed under a key from the vault's
  own Argon2id derivation, not 100,000 rounds of PBKDF2.
- Field detection matches whole words, uses the password field's own
  page, skips hidden and tiny fields, and identifies apps by their current
  signing certificate.

**Second review**
- Generated passphrases come from the EFF Large Wordlist: about 71 bits,
  up from 39.
- A missing write-count record is refused for a vault written more than
  once.
- An unknown key function is reported as a newer version.
- A lockout cannot outlast its own length after a restart.
- Timestamps from a wrong clock cannot drag later edits forward.
- Passphrases are normalised to Unicode NFC, with a fallback so nothing
  sealed before is lost.
- Argon2 settings read from a file are capped at 128 MiB and 6 passes.
- The extension offers no password updates from plain-http pages and skips
  clipped fields.

## Read next

- `SECURITY.md`: what protects your passwords, the known limits, and how to
  report a problem.
- `docs/THREAT_MODEL.md`: who it defends against, and where it stops.
- `docs/FORMATS.md`: every file format, byte by byte.
- `docs/ARCHITECTURE.md`, `docs/SYNC.md`, `docs/CREDENTIAL_PROVIDER.md`.
- The [privacy policy](https://ionized-lychee-386.notion.site/Ringer-Vault-Privacy-Policy-3ea62d06f80a801a929ff1246c6bf913)
  for the app and the browser extension.

## Reporting a problem

Email **ringervault@gmail.com** with "Security" in the subject, with what you
found and how to reproduce it. Please allow reasonable time for a fix before
telling anyone else.

## Licence

Source-available for review under the Ringer Vault Security Review Licence
(`LICENSE`): you may read, build, test and quote it; you may not reuse or
redistribute it. Third-party code keeps its own licence.
