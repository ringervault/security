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
| `docs/` | Architecture, threat model, byte-level formats, sync, the sign-in sheet design, dependencies |
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

At the time of publishing: 583 Dart tests and 212 extension tests, all
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
| Tests never touch real data | `test/support/render_harness.dart` | `leak_audit_test.dart` |

## Read next

- `SECURITY.md`: what protects your passwords, the known limits, and how to
  report a problem.
- `docs/THREAT_MODEL.md`: who it defends against, and where it stops.
- `docs/FORMATS.md`: every file format, byte by byte.
- `docs/ARCHITECTURE.md`, `docs/SYNC.md`, `docs/CREDENTIAL_PROVIDER.md`.

## Reporting a problem

Email **ringervault@gmail.com** with "Security" in the subject, with what you
found and how to reproduce it. Please allow reasonable time for a fix before
telling anyone else.

## Licence

Source-available for review under the Ringer Vault Security Review Licence
(`LICENSE`): you may read, build, test and quote it; you may not reuse or
redistribute it. Third-party code keeps its own licence.
