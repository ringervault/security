# File and wire formats

Every format Ringer Vault writes to disk, to secure storage, to Google Drive
or to a backup file, byte for byte. It is written from the code, so that
someone could build a compatible reader from this page alone. Where the code
is ambiguous, or two pieces of code disagree, this page says so rather than
picking an answer. Those places are collected again at the end.

Conventions used throughout:

- All multi-byte integers are **big-endian** (Dart `ByteData` and JavaScript
  `DataView` both default to it, and neither side overrides it).
- "u32" is an unsigned 32-bit integer; "u64" an unsigned 64-bit one.
- AES-256-GCM always uses a 32-byte key, a 12-byte random nonce and a
  16-byte tag. On the Dart side it is `AesGcm.with256bits()` from
  `package:cryptography`; in the extension it is WebCrypto.
- "base64" means the standard alphabet with `=` padding, on one line, as
  written by Dart's `base64Encode` and the browser's `btoa`. Readers trim
  surrounding whitespace before decoding.
- Text is UTF-8. JSON is whatever `jsonEncode` or `JSON.stringify` produces;
  no reader depends on key order or spacing.

## 1. vault.rvc: the local vault container

Source: `lib/services/vault_container.dart`, `lib/services/storage_service.dart`,
`lib/models/vault_entry.dart`.

One file, `vault.rvc`, in the app's documents folder, holds both vaults: the
real one and the decoy. Both slots are always present and always the same
size.

### File layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic: `52 56 43 31` ("RVC1") |
| 4 | 1 | Version: `0x01` |
| 5 | 3 | Reserved. Written as `00 00 00`. Not checked on read. |
| 8 | S | Slot 0: the real vault |
| 8 + S | S | Slot 1: the decoy vault |

The file is `8 + 2 × S` bytes long. A reader finds `S` as
`(file length - 8) / 2`. There is no length field.

A reader refuses the file when:

- it is shorter than `8 + 2 × 65,536` bytes, or `file length - 8` is odd, or
  the first four bytes are not "RVC1" ("not one Ringer Vault wrote");
- byte 4 is anything other than `0x01` ("written by a newer version"). Note
  that `0x00` gets the same message.

### Slot size buckets

`S` is always one of these sizes, smallest first:

| Buckets | Sizes |
|---|---|
| Doubling | 65,536 (64 KiB), 131,072, 262,144, 524,288 |
| Whole MiB | 1,048,576 × n, for n = 1 to 64 (1 MiB to 64 MiB) |

68 buckets in all. A vault whose JSON is `L` bytes needs the smallest bucket
`B` with `B - 32 ≥ L` (12 nonce, 16 tag, 4 length prefix). Above 64 MiB the
write fails with "The vault is too large to store."

The reader does not check that `S` is one of the buckets. Writers only ever
produce bucket sizes.

### Slot layout

For a vault sealed into bucket `B`, in a slot of size `S ≥ B`:

| Offset in slot | Size | Field |
|---|---|---|
| 0 | 12 | AES-GCM nonce, random |
| 12 | B - 28 | Ciphertext |
| B - 16 | 16 | AES-GCM tag |
| B | S - B | Filler: random bytes from `Random.secure()` |

The ciphertext is exactly as long as the plaintext, so the plaintext is
`B - 28` bytes:

| Offset in plaintext | Size | Field |
|---|---|---|
| 0 | 4 | `L`: length of the JSON, u32 |
| 4 | L | The vault as UTF-8 JSON |
| 4 + L | B - 32 - L | Zero bytes |

The additional data (AAD) is 9 bytes:

    52 56 43 31  01  00 00 00  <slot>

that is the magic, the version, three zero bytes and the slot number
(`0x00` or `0x01`). This binds each slot to its position: slot 0's
ciphertext moved into slot 1 does not authenticate.

### Keys for a slot

Each vault has a 32-byte master key (section 3). Two keys are derived from it
with HMAC-SHA256, the master key as the HMAC key and an ASCII label as the
message (`SlotKeys`):

| Key | Label | Used for |
|---|---|---|
| Slot key | `ringer-vault/container/slot/v1` | AES-256-GCM over the slot |
| Count key | `ringer-vault/container/count/v1` | AES-256-GCM over the write count (section 2) |

Each output is 32 bytes and is used directly as an AES-256 key.

### Finding a slot's length

Nothing outside the encryption records `B`. A reader holding a slot key does
this (`openSlot`):

1. Take the nonce from bytes 0 to 12 of the slot.
2. For every bucket `b`, smallest first, while `b ≤ S`: try to decrypt
   `slot[12 .. b - 16)` with tag `slot[b - 16 .. b)`, the slot key and the
   slot's AAD.
3. The first `b` that authenticates is the vault's bucket. Read `L` from the
   first 4 plaintext bytes. If `L > b - 32` the slot is treated as not
   openable (null). Otherwise decode `plaintext[4 .. 4 + L)` as UTF-8 JSON;
   it must be a JSON object.
4. Keep trying every remaining bucket anyway, discarding the results, so the
   time taken does not say which bucket fitted.

If no bucket authenticates, the slot is not this key's: another vault, random
filler, or an altered slot. These cannot be told apart. The zero padding
after the JSON is not checked on read. A slot that authenticates but holds
invalid UTF-8 or invalid JSON throws from `openSlot` rather than returning
null; it is not caught there.

### The other slot

When this vault writes, it cannot read the other slot, so it copies it byte
for byte from the existing file (`assemble`). The new slot size is the larger
of this vault's bucket and the existing slot size. Whichever slot is shorter
is lengthened with random bytes. With no existing file, the other slot is
random bytes from end to end. Destroying one vault overwrites its whole slot
with random bytes, in both `vault.rvc` and `vault.rvc.prev`
(`destroyVault`).

Slots never shrink. Deleting entries does not make the file smaller; only
erasing both vaults (which deletes the files) does.

### The JSON inside a slot

Source: `_OpenVault.toJson` and `_OpenVault.fromJson` in
`lib/services/storage_service.dart`.

| Key | Type | Written | Read |
|---|---|---|---|
| `v` | integer | Always `1` | **Never read.** See "Versioning". |
| `count` | integer | This vault's write count (section 2) | Required. Must be an integer. |
| `entries` | array of entry objects | Every live entry | Required. Entries are keyed by `id`; a later duplicate replaces an earlier one. |
| `deleted` | object: entry id to timestamp string | Always written. `{}` for the decoy, which never records deletions. | Optional; a missing key reads as `{}`. Values that do not parse as a date are dropped. Times are held as UTC. |
| `log` | array of objects | This vault's activity log | Optional; missing reads as `[]`. |
| `meta` | object | Facts kept inside the vault | Optional; missing reads as `{}`. |

`deleted` timestamps are written with `toUtc().toIso8601String()`, for
example `2026-10-08T09:15:02.123Z`. Dart writes three fractional digits, or
six when the time has microseconds.

Any failure while building the vault from this JSON (a missing `entries`, a
non-integer `count`, an entry that does not parse) is reported as a tampered
vault (`VaultTamperedError`), not as a damaged one.

Keys of `meta` the code uses:

| Key | Type | Meaning |
|---|---|---|
| `decoy` | `true` | Real vault only: a decoy exists. Absent otherwise. (`StorageService.setHasDecoy`) |
| `custom_categories` | array of strings | The vault's own category list (`lib/repository/vault_repository.dart`) |
| `dashboard_categories` | array of strings | Categories shown on the dashboard |
| `inboxKey` | string | This vault's save-inbox private key: 32 random bytes, base64 (section 9). Made the first time the vault opens. |
| `inboxQuestions` | array of objects | Logins saved while locked that look like an entry not linked where they were typed: `entryId`, `entryTitle`, `login` (as in the inbox file), `destination`, and `warning` and `danger`. Removed once answered. |
| `inboxNotice` | array of objects | Logins taken from the inbox and not yet shown: `title`, `updated` (boolean), and `warning` and `danger` when the site looked like one of the vault's own. Removed once shown. |

A `log` record, from `lib/services/activity_log_service.dart`:

| Key | Type | Notes |
|---|---|---|
| `timestamp` | string | `DateTime.now().toIso8601String()`: **local time, no zone suffix** |
| `action` | string | |
| `details` | string or null | |
| `isFailure` | boolean | |
| `isWarning` | `true` | Present only when set |

### The entry object

Source: `VaultEntry.toJson` and `VaultEntry.fromJson` in
`lib/models/vault_entry.dart`. The same object is used inside a slot, inside
a sync record and in a backup.

| Key | Type | If missing on read |
|---|---|---|
| `id` | string | A new random UUID v4 is made. See "Inconsistencies". |
| `title` | string | Read fails |
| `username` | string | Read fails |
| `password` | string | Read fails |
| `category` | string | Read fails |
| `email` | string | `""` |
| `pin` | string | `""` |
| `notes` | string or null | `null` |
| `passwordLabel` | string | `""` (shown as "Password") |
| `extraPassword` | string | `""` |
| `extraPasswordLabel` | string | `""` (shown as "Second password") |
| `pinLabel` | string | `""` (shown as "PIN") |
| `extraPin` | string | `""` |
| `extraPinLabel` | string | `""` (shown as "Second PIN") |
| `autofillTargets` | array | `[]`. Each element is converted to a string. |
| `createdAt` | ISO 8601 string | Read fails (`DateTime.parse`) |
| `updatedAt` | ISO 8601 string | Read fails (`DateTime.parse`) |
| `passwordHistory` | array of `{password, replacedAt}` | `[]`. Optional, added 8 October 2026. Earlier passwords, newest first, five at most, never the current one. `password` is a non-empty string; `replacedAt` is ISO 8601 in UTC. A malformed item is dropped. Written only when not empty. |

"Read fails" means `fromJson` throws: the value is null or not a string. A
value of the wrong type in a defaulted field (a number in `email`, say) also
throws. Every key above is always written (including `notes` as `null`),
except `passwordHistory`, which is left out when empty.

**Dates.** From 8 October 2026 `createdAt`, `updatedAt` and `replacedAt` are
always written in UTC with a trailing `Z`. Files written earlier may hold
local times with no zone; reading accepts both.

**Password history.** When an entry's password changes (an edit in the app,
a save through autofill, an update from the extension), the replaced
password is put in front of `passwordHistory`. The app and the extension
apply the same rule (`withPreviousPassword` in `lib/models/vault_entry.dart`
and `extension/src/vault/save.js`). It is shown only after the entry passes
the same check as revealing its password, and is never in the extension's
copy of entries used for filling.

**Unknown fields are kept.** Any key not in the table above is copied into
the entry's `extra` map on read and written back unchanged by `toJson`
(spread first, so it can never overwrite a known key). An older build that
rewrites an entry therefore does not drop a field a newer build added. The
`extra` map is not in the old Hive record format, which only matters for the
legacy files read once during migration.

`autofillTargets` strings (`lib/autofill/autofill_target.dart`):

| Form | Meaning |
|---|---|
| `site:<host>` | A website, by normalised host (lower case, no "www.") |
| `app:<package>:` | An app named but not yet pinned |
| `app:<package>:<sha256 hex>` | An app pinned to its signing certificate (64 lowercase hex characters) |
| `app:<package>:<sha256 hex>:verified` | As above, confirmed by the site's Digital Asset Links |

A target that does not parse is ignored at fill time but kept in the list.

Timestamps: `createdAt` and `updatedAt` are written with
`toIso8601String()` on the `DateTime` as held, **without** converting to UTC
first. A time held in UTC is written with a `Z`; a local time is written
with no zone at all. Edits made through `StorageService` are stamped in UTC
(`nextStamp`), so `updatedAt` normally ends in `Z`. `createdAt` defaults to
`DateTime.now()`, which is local. See "Inconsistencies".

## 2. Writing vault.rvc, and recovering

Source: `StorageService._write`, `_load`, `_finishInterruptedWrite` and
`destroyVault` in `lib/services/storage_service.dart`; `sealCount`,
`openCount` and `unusedCount` in `lib/services/vault_container.dart`.

Three files are involved, all in the same folder:

| File | Role |
|---|---|
| `vault.rvc` | Current |
| `vault.rvc.new` | The next version, while it is being written |
| `vault.rvc.prev` | The version before the current one, whole, in the same format |

### Write sequence

Writes are queued and run one at a time. Each one:

1. Adds 1 to the vault's in-memory `count`. The first write of a vault
   therefore stores `count = 1`.
2. Takes the other vault's slot from `vault.rvc` if that is a whole
   container, else from `vault.rvc.prev`, else uses random bytes.
3. Seals this vault's slot and assembles the whole file.
4. Writes it to `vault.rvc.new` and flushes.
5. If `vault.rvc` exists, renames it to `vault.rvc.prev` (replacing any older
   `.prev`).
6. Renames `vault.rvc.new` to `vault.rvc`. **This is the commit.**
7. Writes the sealed count to secure storage under the slot's own name.
8. If the other slot's count record does not exist yet, writes a random
   stand-in for it.

Renames within one folder are atomic on Android's file systems, which is
what the order relies on.

### The write count

Secure storage (Keystore-backed `flutter_secure_storage`) holds one record
per slot:

| Secure storage key | Slot |
|---|---|
| `vc_count_a` | 0, real |
| `vc_count_b` | 1, decoy |

Each value is base64 of exactly 36 bytes (48 characters):

| Offset | Size | Field |
|---|---|---|
| 0 | 12 | AES-GCM nonce, random |
| 12 | 8 | Ciphertext of the count, a u64 |
| 20 | 16 | AES-GCM tag |

The key is the slot's count key (section 1). The AAD is the same 9 bytes as
the slot's. A slot nothing has written to holds a stand-in: base64 of 36
random bytes (`unusedCount`). Both records exist on every device after the
first write, so their presence says nothing about a decoy. A record that is
missing, a stand-in, or another key's reads as "no count" (`openCount`
returns null), which the checks below treat as 0.

### Opening, and the "one write behind" rule

On every open (`_load`):

1. **Finish an interrupted write.** If `vault.rvc.new` exists and
   `vault.rvc` does not, and `.new` is a whole container, `.new` becomes
   `vault.rvc` (the write stopped between steps 5 and 6). Otherwise `.new`
   was never committed and is deleted.
2. Read `written`, the count from secure storage.
3. Try to open this vault's slot in `vault.rvc`. If it opens and its `count`
   is lower than `written`, the vault is refused as an older copy put back.
   If it opens with a `count` above 1 and `written` is absent or unreadable,
   it is refused too: the count is recorded straight after the first write,
   so it can only be missing then, and removing it is what putting back an
   older copy unnoticed would need. Otherwise it is the vault.
4. If it does not open and `written > 0`, the vault was written before and
   is now unreadable. Open this vault's slot in `vault.rvc.prev`. If that
   fails, or its `count` is lower than `written - 1`, the vault is refused.
   Otherwise it is used, the user is told the last change may be missing,
   and it is written straight back into `vault.rvc` (a full write, so its
   count goes up by one).
5. If it does not open and `written` is 0 or absent, the vault has never
   been written: it is read from the old Hive files if any exist (and then
   written), or starts empty with `count = 0` (and nothing is written until
   the first change).

Why "one write behind": the count is written after the commit (step 7 of the
write), so it can trail the file by one but never lead it. A file one write
ahead of the stored count is the normal result of a stop between steps 6
and 7, and is accepted. `.prev` is one write behind the current file, so it
is accepted only down to `written - 1`. Anything older is refused, so
damaging the current file cannot be used to bring back an older one.

A missing or unreadable count record no longer switches the check off
(step 3): only a vault written exactly once may have none, after a stop
between its first write and its first count. A keystore that lost its keys
loses the vault's sealed key with them, so refusing locks nobody out of a
vault that could otherwise have opened.

### Erasing

- **One vault** (`destroyVault`): its slot in `vault.rvc` and in
  `vault.rvc.prev` is overwritten with random bytes. Each file is rewritten
  through `vault.rvc.new` and a rename. Its count record becomes a fresh
  stand-in.
- **Both vaults** (`destroyAllVaults`): `vault.rvc`, `.new` and `.prev` are
  deleted, and both count records become fresh stand-ins.

## 3. Key wrapping for the unlock secret

Source: `lib/services/vault_key_service.dart`.

Each vault has a master key: 32 random bytes. It is never stored in the
clear outside the biometric record. It is wrapped under a key derived from
the PIN (the KEK).

### Secure storage records

| Real vault key | Decoy key | Value |
|---|---|---|
| `vk_salt` | `vk_salt_2` | base64 of a 16-byte random salt |
| `vk_kdf_params` | `vk_kdf_params_2` | JSON, see below |
| `vk_wrapped_pin` | `vk_wrapped_pin_2` | base64 of the 60-byte envelope |
| `vk_wrapped_bio` | `vk_wrapped_bio_2` | base64 of the raw 32-byte master key, in biometric-only storage. Present only when fingerprint unlock is on. |

The decoy's records carry a plain `_2`. Older builds named them `_decoy`;
`vk_salt_decoy`, `vk_kdf_params_decoy` and `vk_wrapped_pin_decoy` are copied
to the `_2` names (unless those already exist) and deleted, once per run.

Other records in the same store, for completeness: `vk_device_<purpose>`
(base64 of a 32-byte device-scoped key, today only for the security log) and
`hive_encryption_key` (a pre-envelope master key, read only during
migration).

### KDF parameters

`vk_kdf_params` is a JSON object:

| Key | Type | Native default | Web default |
|---|---|---|---|
| `alg` | `"argon2id"` or `"pbkdf2"` | `"argon2id"` | `"pbkdf2"` |
| `m` | integer, KiB | 32,768 (32 MiB) | 32,768 (recorded, not used) |
| `t` | integer | 3 (Argon2id passes) | 1,200,000 (PBKDF2 iterations) |
| `p` | integer | 1 (lanes) | 1 (recorded, not used) |

- A missing `alg`, or one this build does not know, is read as `argon2id`.
- A missing `vk_kdf_params` record is read as the defaults of the platform
  doing the reading.
- Argon2id: `package:cryptography`'s `Argon2id`, password = the PIN as
  UTF-8, salt = the 16-byte salt, 32-byte output. The code does not set the
  Argon2 version number; it uses the package default.
- PBKDF2: HMAC-SHA256, `t` iterations, 256-bit output.

New parameters and a new salt are chosen on every seal (`_sealWithPin`): on
creating a vault, changing the PIN, or adopting a legacy key.

### Envelope

`vk_wrapped_pin` decodes to 60 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 12 | AES-GCM nonce, random |
| 12 | 16 | AES-GCM tag |
| 28 | 32 | Ciphertext of the master key |

AES-256-GCM with the KEK, **no AAD**. A wrong PIN fails the tag check, so
the envelope is also the PIN verifier; there is no separate PIN hash. An
envelope of 28 bytes or fewer is refused as truncated.

Note the field order: nonce, tag, ciphertext. The container slot and the
count record use nonce, ciphertext, tag. See "Inconsistencies".

### The decoy's stand-ins

The decoy's three PIN records exist on every device. Where there is no
decoy, `ensureDecoyStandIn` writes:

| Record | Stand-in value |
|---|---|
| `vk_salt_2` | base64 of 16 random bytes |
| `vk_kdf_params_2` | the platform defaults, as above |
| `vk_wrapped_pin_2` | base64 of 60 random bytes, the length of a real envelope |

Every PIN fails against the stand-in exactly as a wrong PIN fails against a
real envelope. There is no stand-in for `vk_wrapped_bio_2`. When no
envelope or salt exists at all, an unlock attempt still runs a full key
derivation with a random salt, so the time taken does not say whether the
vault exists.

## 4. Sealed files: versions 1, 2 and 3

Source: `lib/utils/sealed_file.dart` (app) and `extension/src/vault/format.js`
(extension). **These two files must agree byte for byte.** The format is
used by Google Drive sync (section 5) and by exported backups (section 6).
`test/fixtures/argon2id_vector.json` holds an Argon2id vector and a file
sealed by each side that the other must open.

A sealed file is base64 text of the bytes below.

### Version 1 (read only)

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | Salt |
| 16 | 12 | AES-GCM nonce |
| 28 | 16 | AES-GCM tag |
| 44 | rest | Ciphertext |

- Key: PBKDF2-HMAC-SHA256(passphrase, salt, 100,000 iterations, 32 bytes).
- AAD: none (empty).

### Version 2 (read; written by the app's web build)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic: `52 56 4C 54` ("RVLT") |
| 4 | 1 | Version: `0x02` |
| 5 | 1 | KDF: `0x01` = PBKDF2-HMAC-SHA256 |
| 6 | 4 | Iterations, u32 |
| 10 | 16 | Salt |
| 26 | 12 | AES-GCM nonce |
| 38 | 16 | AES-GCM tag |
| 54 | rest | Ciphertext |

- Key: PBKDF2-HMAC-SHA256(passphrase, salt, iterations, 32 bytes).
- Written with 600,000 iterations.
- AAD: bytes 0 to 10 (the header).

### Version 3 (written by the app on Android and iOS)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic: `52 56 4C 54` ("RVLT") |
| 4 | 1 | Version: `0x03` |
| 5 | 1 | KDF: `0x02` = Argon2id |
| 6 | 4 | Memory in KiB, u32 |
| 10 | 4 | Passes, u32 |
| 14 | 1 | Lanes, u8 |
| 15 | 16 | Salt |
| 31 | 12 | AES-GCM nonce |
| 43 | 16 | AES-GCM tag |
| 59 | rest | Ciphertext |

- Key: Argon2id(passphrase, salt, memory, passes, lanes), 32-byte output.
- Written with 65,536 KiB (64 MiB), 3 passes, 1 lane: twice the memory of
  the local vault's PIN key, because this file can be copied away and
  attacked offline.
- AAD: bytes 0 to 15 (the header).
- The app uses `package:cryptography`; the extension uses hash-wasm 4.12.0
  (vendored in `extension/src/vendor`). Neither sets the Argon2 version
  number; the shared test vector is what holds them together.

The passphrase is encoded as UTF-8 on both sides, with no Unicode
normalisation.

### Reading

Both readers do the same, in this order:

1. Trim whitespace and base64-decode. Failure: "not a Ringer Vault file".
2. **Version.** If the decoded bytes are longer than 10 and start with
   "RVLT", the version is byte 4. Otherwise the file is version 1.
3. Version 2: byte 5 must be `0x01`, else "made by a newer version".
   Iterations must be from 100,000 to 10,000,000, else "not ours".
4. Version 3: the file must be longer than 15 bytes. Byte 5 must be `0x02`,
   else "made by a newer version". Then memory must be from 19,456 KiB
   (19 MiB) to 131,072 KiB (128 MiB), passes from 1 to 6, lanes from 1 to
   8, and memory at least 8 × lanes, else "not ours". These limits stop a
   crafted file from stalling or crashing the device (they are checked
   before the file can be authenticated) or settling for a weak key. The
   extension applies the same limits.
5. Any other version byte: "made by a newer version".
6. The file must be longer than header + 16 + 12 + 16 bytes, so at least
   one byte of ciphertext. (A sealed empty plaintext cannot be read back.
   Neither writer ever seals one.)
7. Derive the key and decrypt with the header as AAD. A wrong passphrase
   and an altered file give the same error, on purpose.

A version 1 file whose random salt happens to begin with "RVLT" would be
misread as another version, or refused as "made by a newer version". The
chance is 1 in 2^32 per file; nothing in the format rules it out.

### Writing

| Writer | Version written | Salt |
|---|---|---|
| App, Android and iOS | 3 | Backups: fresh. Sync: the salt of the last file read this session, else fresh (`SyncCipher`). |
| App, web build | 2 (600,000 iterations). Refuses to replace a sync file it read as version 3 (`SyncDowngradeRefused`). | As above |
| Extension, new synced vault | 3 (`newKey`) | Fresh |
| Extension, any later write | The version and parameters it read, including 1 and 2 (`seal`) | The salt it read |

The extension holds a derived key, not the passphrase, so it can only
write back with the parameters that key was made with. The app upgrades a
version 1 or 2 sync file to version 3 the next time it writes.

The nonce is always fresh, from `Random.secure()` (Dart) or
`crypto.getRandomValues` (extension). Reusing the salt, and so the key, is
safe for AES-GCM only because of that.

WebCrypto returns ciphertext and tag joined; the extension splits off the
last 16 bytes as the tag on write, and joins them again on read. That is
the whole of the adaptation.

### Differences between the app and the extension

Byte layout, KDF settings, limits and error conditions agree. What differs:

- The comment at the top of `format.js` says both version 2 and version 3
  are "written for anything new". The code writes version 3 for a new
  vault, and otherwise the version it read. The comment is stale.
- The extension writes version 1 and 2 files back in their own version; the
  app upgrades them. Expected, and documented in `docs/SYNC.md`.
- Base64 is decoded by different library functions (`base64Decode` in
  Dart, `atob` in the browser). Both are given standard padded base64 by
  both writers, but the code does nothing to make them agree on unusual
  input (embedded line breaks, the URL-safe alphabet, missing padding).
- After decrypting, the extension parses JSON at once and accepts either a
  JSON array (a backup) or a sync object. The app's backup importer accepts
  only an array, and its sync reader only a sync object.

## 5. The Google Drive sync payload

Source: `lib/sync/sync_payload.dart`, `lib/sync/sync_merge.dart`,
`lib/sync/sync_engine.dart`, `lib/sync/sync_cipher.dart`,
`lib/sync/drive_transport.dart`; `extension/src/vault/format.js`,
`extension/src/vault/save.js`, `extension/src/vault/rollback.js`,
`extension/src/vault/drive.js`, `extension/src/background.js`.

### The file in Drive

One file named `ringer-vault.sync` in the Drive **app data folder**
(`appDataFolder`), uploaded with `Content-Type: text/plain`. Its content is a
sealed file (section 4) as base64 text. The plaintext inside is UTF-8 JSON:

| Key | Type | Notes |
|---|---|---|
| `format` | string | Exactly `"ringer-vault-sync"`. Anything else is refused. |
| `version` | integer | `2`. A reader refuses a larger number. |
| `writtenBy` | string | Who wrote this copy. App: a random device label, 12 random bytes as unpadded base64url (16 characters), kept in secure storage as `sync.deviceId`. Extension: `"chrome-extension"`. Informational only. |
| `writtenAt` | string | ISO 8601. App: its clock at upload, in UTC. Extension: the same stamp it gave the change (see `nextStamp`), or the time of creation. Informational only. |
| `generation` | integer ≥ 0 | One more than the copy it replaced. Absent in version 1 files; read as 0. |
| `records` | array | One per entry id, live or deleted |

`writtenBy` and `writtenAt` are parsed by the app but nothing decides
anything by them.

A record:

| Key | Type | Notes |
|---|---|---|
| `id` | non-empty string | The entry's id |
| `updatedAt` | ISO 8601 string | When this version was written. **This** is what merging compares. |
| `entry` | entry object (section 1) | Present for a live entry |
| `deleted` | `true` | Present, instead of `entry`, for a deletion record (tombstone) |

The app writes `updatedAt` with `toUtc().toIso8601String()`. The extension
writes `Date.prototype.toISOString()`, also UTC with `Z`.

### Reading rules (app)

- Not valid JSON, not an object, or `format` wrong: refused.
- `version` not an integer, or greater than 2: refused ("written by a newer
  version").
- `records` not an array, or `generation` present and not a non-negative
  integer: refused as damaged.
- A record with `deleted == true` is a tombstone, whatever else it holds.
  Otherwise it must have an `entry` object. A record that is not an object,
  has no non-empty string `id`, has an `updatedAt` that is not a string or
  does not parse, or (when live) has no `entry` object, makes the **whole
  file** refused: skipping it would let the next write drop it everywhere.
- Two records with the same id: the one that would win a merge is kept.
- Before anything is written locally, every incoming live entry must build
  with `VaultEntry.fromJson`, and its `entry.id` must equal the record's
  `id` (`StorageSyncVault.canStore`). One failure refuses the whole file.

### Reading rules (extension)

- `format` is checked for a sync object; a JSON array is taken as a backup.
- `version` must be a number (not checked to be an integer) and at most 2.
- `records` must be an array.
- For filling, records with `deleted === true` are dropped and each other
  record's `entry` is read leniently: missing strings become `""`, and a
  missing or non-object entry is skipped. Only `id`, `title`, `username`,
  `email`, `password`, `category`, `notes` and `autofillTargets` are kept in
  memory.
- For writing, the extension edits the decrypted file as it was read
  (`applySave`, `applyLink`, `mergeIntoSync`), so every other record and
  every field it does not show (PINs, second passwords, unknown fields)
  passes through untouched.

### Writing

- The app builds the object afresh from its merged records, and writes
  exactly the six keys above. A deleted record is written as
  `{"id", "updatedAt", "deleted": true}` with no `entry`.
- The extension spreads the parsed object (`{...parsed}`), replaces
  `writtenBy`, `writtenAt` and `records`, and then sets `version` to 2 and
  `generation` to the next value (`nextCopy`). A record it changes or adds
  is written as `{"id", "updatedAt", "entry"}`, with `updatedAt` equal to
  the entry's own `updatedAt`.
- A new entry from the extension carries every key `VaultEntry.fromJson`
  reads, with `notes: null` and empty strings for the rest. `save.js`
  uses category `"Social"`; an import (`importing.js`) guesses one.

### Merging and deletions

Per entry, the later `updatedAt` wins (`pickWinner`). On an exact tie, a
deletion beats a live entry; otherwise the record whose canonical JSON
(keys sorted, `jsonEncode` for leaves) compares greater wins. The app drops
deletion records older than 180 days on every sync (`pruneTombstones`). The
extension does not prune.

Both sides stamp their edits with a hybrid logical clock: "now", unless
something in the vault is stamped later, in which case 1 ms after that
(`StorageService.nextStamp`, `nextStamp` in `save.js`).

### The rollback rule

Every write numbers the file one above the copy it replaced, and each device
remembers the highest generation it has accepted (`seen`):

| Side | Where `seen` is kept |
|---|---|
| App | Secure storage, `sync.mark.generation` (a decimal string), beside `sync.mark.version` and `sync.mark.hash` |
| Extension | `chrome.storage.local`, `ringer.syncGeneration` |

Both sides implement the same function, `generationStep(found, seen,
acceptOlder)` (`lib/sync/sync_engine.dart` and
`extension/src/vault/rollback.js`; `test/fixtures/rollback_cases.json` holds
cases both must pass):

    if found < seen and not acceptOlder: refuse
    otherwise: next generation to write = max(found, seen) + 1

- On reading, `acceptOlder` is false. A refused copy is not merged and
  nothing is written on either side.
- On writing, `acceptOlder` is true, so the new copy is numbered above
  anything either side has seen.
- The app takes an older copy only after the sync passphrase is typed again
  (`acceptOlder: true` for that run), and then always writes it back with a
  higher number. The extension takes one on reconnecting with the
  passphrase (`adoptCopy`, which sets `seen` to the copy's generation).
- A new synced vault starts at generation 1. A device with no `seen` (new,
  reinstalled, or signed out) has `seen = 0` and accepts anything.

## 6. The exported backup file

Source: `getEncryptedJson`, `encryptData`, `_encryptBackup`,
`importFromEncryptedJson`, `_decryptBackup`, `getAllEntriesAsJson` and
`importEntriesFromJson` in `lib/services/storage_service.dart`;
`lib/screens/export_import_screens.dart`.

The app exports a backup as a text file named `ringer_vault_backup.enc`,
handed to the system share sheet and then deleted from the app's temporary
folder.

### Outer layer

The file's content is a **sealed file, section 4**, as base64 text. It is
not a separate format. `_encryptBackup` uses `SealParams.fresh()`, so:

- on Android and iOS: version 3, Argon2id 64 MiB, 3 passes, 1 lane, fresh
  16-byte salt;
- in the web build: version 2, PBKDF2-HMAC-SHA256 600,000 iterations,
  fresh 16-byte salt.

The layout "salt (16) || nonce (12) || mac (16) || ciphertext, base64,
PBKDF2" is version 1 only. Version 1 backups are still read (PBKDF2-HMAC-
SHA256, 100,000 iterations, 32-byte key, no AAD), but no current build
writes one.

On import, the text is trimmed and base64-decoded, and must be longer than
44 bytes (the version 1 minimum) before it is handed to the sealed-file
reader, which applies its own, stricter, checks for versions 2 and 3.

### Plaintext

**The backup plaintext is a UTF-8 JSON array of entry objects (section 1),
with no version field and no format marker inside it.** It holds the live
entries of the open vault only: no deletion records, no activity log, no
`meta`, no write count. Unknown entry fields (`extra`) are included.

The extension tells a backup from a sync file by the JSON's shape: an array
is a backup, an object with `"format": "ringer-vault-sync"` is a sync file.

### Import rules (app)

- The decrypted JSON must be an array. Each element must build with
  `VaultEntry.fromJson`; one failure stops the import and nothing is
  written.
- Merged, not pasted over: an incoming entry is taken only if its
  `updatedAt` is strictly later than the local copy's, and strictly later
  than any local deletion of the same id. Taken entries keep their own
  `updatedAt`.
- The SHA-256 of the file's text is remembered after a successful import,
  and the same file is refused a second time ("Already imported").

## 7. Padding and size hiding

What is padded:

| Where | How |
|---|---|
| A vault's JSON inside its slot | Zero-padded to a bucket: 64, 128, 256, 512 KiB, then whole MiB up to 64 MiB |
| The two slots | Always the same size: the larger of the two. The shorter vault's sealed slot is followed by random bytes. |
| An unused or erased slot | Random bytes of the full slot size |
| Slot size over time | Never shrinks while the file exists |
| Write count records | 36 bytes, real or stand-in, for both slots |
| Save inbox keys | Always both, real or a random stand-in (section 9) |
| A save inbox file | Plain text padded to a multiple of 512 bytes; both copies always present, a taken one overwritten with random bytes |
| Decoy key records | Always present; the stand-in envelope is 60 bytes, the same as a real one |
| Opening a slot | Every bucket up to the slot size is tried, whatever fits first |

So `vault.rvc` shows only which bucket the larger vault is in. It does not
show whether a decoy exists or which vault is larger.

What is **not** padded:

| Where | What it shows |
|---|---|
| The Drive sync file | Its length is the plaintext JSON length plus a fixed header (59 bytes in version 3), then base64. Google can see roughly how much the vault holds, and every change in size. |
| An exported backup | The same: its length follows the JSON array exactly. |
| `writtenBy`, `writtenAt`, `generation` | Inside the encryption, so not visible, but their lengths count towards the file's. |

## 8. Versioning and forward compatibility

| Format | Version is | Current | A reader meeting a newer one |
|---|---|---|---|
| `vault.rvc` | Byte 4 | 1 | Refuses ("written by a newer version") |
| Slot JSON | `"v"` | 1 | **Does not check it** (see below) |
| Slot and count keys | The `/v1` in the HMAC labels | v1 | Not detectable: a new label just fails to open |
| PIN envelope KDF | `alg` in `vk_kdf_params` | `argon2id` or `pbkdf2` | Treats an unknown `alg` as `argon2id`; the unlock then fails like a wrong PIN |
| Sealed file | Byte 4 after "RVLT"; KDF byte 5 | 3 | Refuses ("made by a newer version"), also for an unknown KDF byte |
| Sync payload | `"version"` | 2 | Refuses, in the app and the extension |
| Backup plaintext | None | | Cannot tell; the app requires a JSON array |
| Entry object | None | | Keeps unknown fields |
| Save inbox file | Byte 4 after "RVI1" | 1 | Skips the file; it is removed after 90 days like any it cannot open |

**Unknown entry fields survive a rewrite** everywhere an entry is rewritten:

- in the local vault, through `VaultEntry.extra`;
- through app sync, which carries `entry.toJson()`, `extra` included;
- through the extension, which copies the entry object with a spread and
  changes only the fields it sets;
- in an exported backup and its import.

Unknown keys at the other levels are **not** all kept:

- The app rewrites the sync payload's top level and each record from known
  keys only, so unknown top-level or record-level keys are dropped by its
  next write. The extension keeps unknown top-level keys, and unknown keys
  on records it does not touch.
- The app rebuilds the slot JSON from known keys, so an unknown top-level
  key in a slot is dropped on the next write. Unknown keys inside `meta`
  are kept.

## 9. The save inbox: logins saved while locked

Source: `lib/services/save_inbox.dart`.

A login saved through autofill or the sign-in sheet is not written into the
vault, which stays locked. It is sealed to both vaults' public keys and left
in a file of its own; whichever vault opens next takes its copy in.

### Keys

Each vault has an X25519 key pair. The private key is `meta.inboxKey`
(section 1), inside the vault. The public keys are in secure storage:

| Record | Holds |
|---|---|
| `vi_key_a` | Slot 0's public key, base64 of 32 bytes |
| `vi_key_b` | Slot 1's public key, base64 of 32 bytes |

Opening a vault writes its own public key into its record if it differs,
and a random 32 bytes into the other record if that one is missing. So
once any vault has opened, both records exist, and a random stand-in looks
the same as a real key. Erasing a vault replaces its record with random
bytes; erasing everything deletes both. Until a record exists (a phone
updated to this version on which no vault has opened yet), saves are made
the older way, after an unlock.

### Files

`inbox/<32 hex characters>.rvi` beside `vault.rvc`, written as `.tmp` and
renamed. Layout:

| Bytes | Field |
|---|---|
| 0 to 3 | ASCII `RVI1` |
| 4 | Version, `1` |
| 5 to 7 | Zero |
| 8 to 11 | The day it was saved: whole days since 1970-01-01 UTC, unsigned, big-endian |
| 12 onwards | Copy for slot 0, then copy for slot 1, the same length |

A copy is:

| Field | Size |
|---|---|
| Ephemeral X25519 public key | 32 |
| Nonce | 12 |
| AES-256-GCM ciphertext | the padded plain text |
| Tag | 16 |

Key: X25519 of the ephemeral private key and the slot's public key, through
HKDF-SHA256 with salt = ephemeral public key || slot public key and info =
ASCII `RVI1 save inbox`, 32 bytes. Additional data: bytes 0 to 11, then one
byte, the slot number.

Plain text: a 4-byte big-endian length, the login as UTF-8 JSON, then zeros
to a multiple of 512 bytes:

| Key | Type | Notes |
|---|---|---|
| `request` | object | Who asked: `packageName`, `certificateSha256`, `claimedWebDomain`, `fromVerifiedBrowser`, `installedFromStore`, `compatibilityMode`, `webScheme`, `knownBrowser`, as the save screen had them |
| `appLabel` | string or null | The app's own name, for naming and suggestions only |
| `title`, `username`, `password`, `category` | strings | As on the save sheet |
| `savedAt` | string | UTC, ISO 8601 with `Z` |
| `warned` | array of strings | Warnings shown on the sheet and saved anyway |
| `warnedDanger` | boolean | Whether any of them was red |

### Taking

On every open, the vault: removes `.tmp` files; opens its own copy of each
file, however old (a copy that does not open is another vault's, already
taken, or not one at all; such a file is removed once it was saved more
than 90 days ago, and otherwise left); and for each login it can open:

- the same account in an entry already linked to exactly that app or site
  gets the new password, its old one going into `passwordHistory`;
- the same account in an entry that is not linked there (suggested by its
  name, or linked to another part of the site) is not changed: the login
  waits in `meta.inboxQuestions`, and the app asks whether to update that
  entry (which also links it there) or save a new one;
- an identical password adds nothing; anything else becomes a new entry
  linked to the app or site.

Each is logged, with "despite warning" when a warning was red, including a
look-alike of the vault's own sites, which could only be checked now. The
vault's copy is then overwritten with random bytes. Nothing deletes a file
sooner than 90 days, whichever vault opened, so the files look the same
after either vault's unlock.

At most 300 files wait at once; the next save is refused with a message
until older ones expire.

## Inconsistencies and open questions

Found while writing this page. None is fixed here.

1. **Slot JSON `"v"` is never read.** `_OpenVault.toJson` writes `"v": 1`;
   `fromJson` ignores it. A future build that changes the slot's meaning
   has no way to make an older build refuse it (the container's byte 4 is
   the only check).
2. **Entry timestamps may have no zone.** `VaultEntry.toJson` writes
   `createdAt` and `updatedAt` without `toUtc()`. `createdAt` is usually
   local time with no suffix; `updatedAt` is usually UTC, but entries that
   bypass `nextStamp` (for example those written by `seedVault`) can carry
   a local `updatedAt` too. Dart and JavaScript both read a zoneless time as
   the reading device's local time, so two devices in different zones read
   the same string as different instants. Activity log `timestamp`s are
   also local with no zone.
3. **Record `updatedAt` and entry `updatedAt` can disagree.** Merging uses
   the record's; the app stores the entry's (`applySyncedEntry` keeps
   `VaultEntry.fromJson(entry).updatedAt`), and its next snapshot reports
   that as the record's. Both writers keep the two equal, but a reader of a
   file where they differ will see the stamp change after one app sync.
4. **An entry without `id` gets a new random one on every read.** In a
   backup, re-importing such a file would add duplicates (the hash check
   stops only the identical file). Sync is protected by `canStore`, which
   requires `entry.id == record.id`.
5. **`generation` is read differently.** The app refuses a file whose
   `generation` is present but not a non-negative integer. The extension
   (`generationOf`) reads the same file as generation 0 and carries on.
6. **`version` is read differently.** The app requires an integer; the
   extension accepts any number up to 2 (for example `1.5`).
7. **Malformed sync records.** The app refuses the whole file; the
   extension skips such records when filling and passes them through when
   writing.
8. **Three orders for AES-GCM output.** The container slot and count record
   use nonce, ciphertext, tag. The PIN envelope and sealed files use nonce,
   tag, ciphertext (sealed files with the salt first). Each is internally
   consistent; a reader must not assume one order.
9. **Stale comments in the code**, which this page does not follow:
   - `extension/src/vault/format.js` says version 2 is "written for
     anything new" as well as version 3.
   - `lib/sync/sync_cipher.dart` says it "always writes version 2
     (PBKDF2-SHA256 at 600,000 iterations)". It writes version 3 except in
     the web build.
   - `StorageService.getEncryptedJson` is commented "Encrypt using AES-GCM
     with PBKDF2 key derivation". It uses Argon2id (version 3) except on web.
   - `_decryptBackup` says it reads "either format version". There are
     three.
   - The `VaultKeyService` class comment says the master key "is what Hive
     actually encrypts with". The vault is now in `vault.rvc`, under keys
     derived from the master key; Hive is used only to read old files once.
10. **Fixed:** an unknown `alg` in `vk_kdf_params` is refused as "made by a
    newer version", not guessed at as Argon2id; it is not counted as a
    wrong attempt. An absent `alg` still means Argon2id, as on older vaults.
11. **Fixed:** a missing or unreadable count record is refused for a vault
    written more than once (section 2).
12. **The Argon2 version number is implicit.** Neither side passes one; both
    rely on their library's default, and the shared vector catches drift.
13. **Fixed:** secrets with letters that can be composed more than one way
    are normalised to NFC for new keys, on both sides
    (`lib/utils/secret_text.dart`, `secretForms` in `format.js`; Android's
    `java.text.Normalizer` in the app). Opening tries NFC first, then the
    text as typed, so anything sealed before still opens. Plain ASCII is
    unchanged.
14. **Timestamps from a wrong clock.** An edit's stamp follows the newest
    stamp in the vault (a hybrid logical clock), but ignores any more than a
    day ahead of this phone's clock, except the entry being edited itself.
    Deletions stamped more than a day ahead are pruned at the next sync.
