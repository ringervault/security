# Google Drive sync

Keeps the vault in step between the app on each device, and lets the browser
extension read it.

## What Google can and cannot see

Google Drive holds one file, `ringer-vault.sync`, in the app's hidden
**app data folder**. It is encrypted before it leaves the device with a sync
passphrase that is never sent anywhere:

Version 3, written by everything from now on:

    base64( "RVLT" || 0x03 || 0x02 || memory KiB(u32) || passes(u32) || lanes(u8)
            || salt(16) || nonce(12) || mac(16) || ciphertext )
    key = Argon2id(passphrase, salt, 64 MiB, 3 passes, 1 lane, 256 bits)
    ciphertext = AES-256-GCM, with the 15-byte header as additional data

The extension runs Argon2id through WebAssembly (hash-wasm 4.12.0, vendored
in `extension/src/vendor` and pinned by its SHA-256), and
`test/fixtures/argon2id_vector.json` holds a vector both sides must compute
and a file each side sealed that the other must open.

Version 2 (PBKDF2-HMAC-SHA256, 600,000 iterations, 10-byte header) and
version 1 (100,000 iterations, no header) are still read. The app rewrites an
older sync file in version 3 the next time it syncs; the extension, which
holds no passphrase, writes back in whichever version it read. The web build
of the app still writes version 2: pure-Dart Argon2id would freeze a browser
tab. The format is
defined once per language: `lib/utils/sealed_file.dart` and
`extension/src/vault/format.js`.

This is the same format as an exported backup, which is why the extension
reads both with one piece of code.

The only scope requested is `drive.appdata`. It reaches the hidden folder and
nothing else: not the user's documents, not their photos, not a list of what
they have.

Google can see that the file exists, its size, and when it changes.

## What changed about "offline"

Sync needs the `INTERNET` permission, and Android permissions are fixed at
install. So from this release the app **can** reach a network, for every user,
whether or not they turn sync on. Before, "it cannot reach a network" was
something anyone could verify from the APK; now Strict Offline Mode is a rule
enforced by the app's own code.

What still holds:

- Sync is off until the user turns it on.
- With Strict Offline Mode on, sync does not run, and does not so much as
  check Drive. This is checked before any network call, and tested.
- Besides sync, the app goes online only to ask a website whether an app
  is its own before a first autofill into that app, and, if the user turns
  it on, to ask how new a website is. The privacy policy lists all three,
  and Strict Offline Mode stops all three.
- The decoy vault never syncs. Its entries can be edited as the real
  vault's can, and the edits stay in the decoy.

Anything published that says the app cannot reach a network needs rewording.

## How merging works

Per entry, last writer wins, compared by each entry's `updatedAt`. Edits to
different entries on different devices both survive. See
`lib/sync/sync_merge.dart`.

Deletions are recorded, not just carried out. Without that, an entry deleted
on the phone is indistinguishable from one the browser has and the phone does
not, and the next sync brings it back. That is the worst possible outcome for a
password deleted after a breach. Deletion records are kept for 180 days.

Every sync reads, merges, writes locally, then writes to Drive. That order is
what makes a collision harmless: a device's own changes stay on the device
until they are in a copy in Drive, so if another device's write lands on top,
the next sync puts them back. This matters because Google Drive does not
enforce conditional writes; the tests run a server that ignores them and
check nothing is lost.

If the passphrase does not open the copy in Drive, sync stops. It never
replaces a copy it cannot read, because that copy is another device's data.

### Known limitations

- **Password history follows the winning edit.** Each entry's earlier
  passwords travel inside it. When two devices change the same entry's
  password without syncing in between, the later edit wins whole, and the
  other device's new password is not added to the history.
- **Clock skew.** Edits are stamped by a hybrid logical clock, so an edit
  made after seeing another device's change always wins. Only two edits to
  the same entry, made on devices that had not synced in between, are
  decided by their clocks.
- **An older copy put back.** Every write numbers the file one higher than
  the copy it replaced (its `generation`, inside the encryption), and each
  device remembers the highest it has accepted. An older file restored in
  Drive is refused with an alert, and nothing is merged or written. The app
  takes it only after the sync passphrase is typed again; the extension,
  after signing in to Drive again with the passphrase.
- **A device with nothing to compare against.** That protection is a
  device's memory of the highest generation it has accepted. A device
  syncing for the first time (a new phone, a reinstall, the extension on a
  new browser, or any device after signing out of sync) has no such
  memory, and takes whatever copy is in Drive, older or not. Someone able
  to write to the Drive account could put back an old copy just before a
  new device joins, and that device would not notice; devices already
  syncing would refuse it, and the next write from one of them would be
  refused nowhere. This is inherent: nothing outside the file, and so
  nothing an attacker cannot also roll back, could tell the new device
  otherwise.
- **The web build writes the older format.** It cannot run Argon2id at a
  usable speed, so it writes version 2. It never writes over a file already
  in version 3: it says so, and keeps its changes on that device for the
  app or the extension to send.
- **Long absences.** A device away for more than 180 days that still holds an
  entry deleted elsewhere will bring it back, because the record of the
  deletion has expired.
- **Erasing is local.** Self-destruct and panic erase remove the vault from
  the device, not from Drive. The sync screen says so. To remove the Drive
  copy, turn sync off and choose to delete it.
- **Damaged files are refused whole.** A file that does not decrypt, does
  not parse, or holds an entry this device cannot store is refused with an
  alert before anything is written on either side.

## Google credentials

Configured on 2026-09-29 in the Google Cloud project `ringer-vault`
(account mojestreaming@gmail.com).

| What | Value |
|---|---|
| Consent screen | App name "Ringer Vault", support email mojestreaming@gmail.com (shown to everyone who signs in), user type External |
| Publishing status | **In production** since 2026-09-29: any Google account can sign in. No verification needed, because there is no logo, one authorized domain, and only a non-sensitive scope. Adding a logo or a sensitive scope later would require verification. |
| Home page | https://ionized-lychee-386.notion.site/Ringer-Vault-3ea62d06f80a80778afafd5120201f90 (Notion, workspace "Moje streaming's Notion") |
| Privacy policy | https://ionized-lychee-386.notion.site/Ringer-Vault-Privacy-Policy-3ea62d06f80a801a929ff1246c6bf913. Also required by the Play Console. The source text is `docs/site/privacy.md`; keep the two in step. |
| Authorized domain | `ionized-lychee-386.notion.site` |
| Scope | `drive.appdata`, which Google classifies as **non-sensitive**, so it needs no app verification on its own |
| Web client | `493444130332-436eu60en5lva7n28ja7p6l6nt2qape9.apps.googleusercontent.com`, used by Android sign-in as the server client ID. Its secret was not saved; nothing here needs it, and a new one can be added from the client page if a server ever does. |
| Android client (debug) | `…-ao3kl83krmkp0hbg69j5khdk2qu3kqv6`, package `ringervault.password.manager`, debug key SHA-1 `44:5E:BC:D6:EF:AC:66:78:14:54:8C:94:FE:86:A1:73:35:58:ED:A4` |
| Android client (upload) | `…-l6kfveda68vufb6r6eg0ek5b61isqtj0`, package `ringervault.password.manager`, upload key SHA-1 `55:51:4A:49:F8:A3:6E:BC:86:DD:58:C6:D2:53:3D:01:63:D2:9B:94` (`android/upload-keystore.jks`, created 2026-09-29) |
| Android client (Play signing) | `…-e7h4909gf74pjfoj1369kbngan8li639`, package `ringervault.password.manager`, Google Play's app signing key SHA-1 `AC:BE:CF:35:F9:6C:CD:F1:C1:B8:B8:F5:96:7A:92:C4:B6:F4:E5:89` (Play Console, Protected with Play, Manage Play app signing). Builds installed from Play are re-signed with this key; added 26 October 2026. |
| Old Android clients | `…-am4ieib6lcp0jb31cueiej48mhi55453` (debug) and `…-sjspb48gqptidf7857t1tm0nenm08a3f` (upload), for the package `com.ringer.vault` the app had until 25 October 2026. Kept only while a phone still has that build; delete them once its vault has moved to the new one. |

Android clients are never referenced in code: Google matches them by package
name and signing key, one fingerprint per client.
| Web client redirect URI (extension) | `https://fbjeclhjjcdkcgojmlfpkliikbibaoji.chromiumapp.org/`, under "Authorized redirect URIs" on the web client. Needed for the extension's "Use a different Google account", which signs in through Google's own window (chrome.identity.launchWebAuthFlow) because Chrome's identity always uses the account Chrome is signed in to. |
| Chrome Extension client | `493444130332-d7b8or52u782ksnb001qgrbd3bmblqe6.apps.googleusercontent.com`, for extension ID `fbjeclhjjcdkcgojmlfpkliikbibaoji`: the Chrome Web Store item, and the unpacked copy too, since `manifest.json` carries the store's public key. (Before 22 October 2026 the unpacked copy used `eoghegloonpklmlnejphbkjaikihgdao`, from `secrets/extension-dev-key.pem`.) |

Client IDs are not secrets; every shipped app contains one. The web client ID
is built into `lib/sync/google_drive_auth.dart` as a default, so every way of
running the app has it, including Android Studio's Run button.
`config/google_oauth.json` (or `--dart-define=GOOGLE_WEB_CLIENT_ID=...`)
overrides it, so a fork can point at its own project.

Google notes that changes can take from 5 minutes to a few hours to apply.

### Building the app

    flutter run --dart-define-from-file=config/google_oauth.json
    flutter build apk --release --dart-define-from-file=config/google_oauth.json

The define is optional now; without it the built-in client ID is used.

### The extension ID

`chrome.identity` only issues tokens to the extension ID registered on the
Chrome Extension client. The ID is fixed by the `key` in `manifest.json`,
the Chrome Web Store item's public key, whose private half only the store
holds. Loading the unpacked extension from any folder gives the same ID.

`chrome.identity.getAuthToken` is Chrome's; Edge and Brave do not support it,
and would need `launchWebAuthFlow` instead.

## Tests

    flutter test test/sync_merge_test.dart          # merging, 200 random histories
    flutter test test/sync_engine_test.dart         # the flow, races, refusals
    flutter test test/drive_transport_test.dart     # Drive API against a fake
    flutter test test/sync_storage_test.dart        # deletion records on disk
    flutter test test/extension_interchange_test.dart   # app writes, extension reads
    npm test --prefix extension
