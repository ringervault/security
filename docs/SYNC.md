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

## Tests

    flutter test test/sync_merge_test.dart          # merging, 200 random histories
    flutter test test/sync_engine_test.dart         # the flow, races, refusals
    flutter test test/drive_transport_test.dart     # Drive API against a fake
    flutter test test/sync_storage_test.dart        # deletion records on disk
    flutter test test/extension_interchange_test.dart   # app writes, extension reads
    npm test --prefix extension
