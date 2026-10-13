# Dependencies

Third-party code in the app and the extension, at the versions in use.
`pubspec.lock` is the full list for the app (138 packages, transitive ones
included); this page lists the direct ones and what each is for.

Last scanned 8 October 2026 with osv-scanner against `pubspec.lock`: no known
vulnerabilities. hash-wasm 4.12.0 has no advisories in the OSV database.

To scan again:

```bash
osv-scanner scan --lockfile pubspec.lock
```

```bash
flutter pub outdated
```

## App (Flutter 3.44.2)

| Package | Version | Used for |
|---|---|---|
| cryptography | 2.9.0 | AES-GCM and Argon2id: the vault, sync file and backups |
| crypto | 3.0.7 | SHA-256 and HMAC: slot subkeys, sync content hashes, clipboard clearing |
| flutter_secure_storage | 10.0.0 | Keystore-backed storage for sealed keys and counters |
| local_auth (+ _android, _darwin) | 2.3.0 (1.0.56, 1.6.1) | Fingerprint unlock |
| hive, hive_flutter | 2.2.3, 1.1.0 | The device security log, and reading vaults from older versions. Not actively maintained; see SECURITY.md |
| google_sign_in (+ _platform_interface) | 7.2.0 (3.1.0) | Google Drive sync sign-in |
| http | 1.6.0 | Drive, a website's app list, the new-site check |
| connectivity_plus | 6.1.5 | Strict Offline Mode's network check |
| safe_device | 1.3.8 | Root check only |
| sensors_plus | 6.1.2 | Panic shake |
| file_picker | 10.3.7 | Choosing a backup or CSV to import |
| share_plus | 12.0.1 | Sharing an exported backup |
| path_provider | 2.1.5 | The app's files folder |
| shared_preferences | 2.5.4 | Settings that hold nothing about the vault |
| uuid | 4.5.2 | Entry ids |
| intl | 0.20.2 | Date formatting |
| cupertino_icons | 1.0.8 | Icons |

Behind by a major version, held back until after the first release so the
release is the code that was tested: connectivity_plus (7), file_picker (13),
flutter_secure_storage (11), local_auth (3), sensors_plus (7), share_plus (13).

## Android (Kotlin, in android/app/build.gradle.kts)

| Library | Version | Used for |
|---|---|---|
| androidx.credentials:credentials | 1.6.0 | The Credential Manager provider (Android 14 and later). Already brought in by google_sign_in; named directly because the provider uses it |
| junit:junit (tests only) | 4.12 | Kotlin unit tests of the caller and hand-over rules |

There is no Gradle lockfile, so osv-scanner does not cover these; the
credentials library is Google's own, at its current stable version.

## Extension

No npm dependencies. One vendored library:

| Library | Version | Used for |
|---|---|---|
| hash-wasm (Argon2id only), MIT | 4.12.0 | Argon2id, in `extension/src/vendor/`, checked by SHA-256 in a test |

## Data

| What | Where | Licence |
|---|---|---|
| EFF Large Wordlist for Passphrases (7,776 words), by the Electronic Frontier Foundation, https://www.eff.org/dice | `tool/eff_large_wordlist.txt`, generated into `lib/utils/eff_words.g.dart` and `extension/src/vault/eff_words.js` (SHA-256 checked by `tool/gen_eff_words.py`) | CC BY 3.0 US |

