# Architecture

How Ringer Vault's parts fit together. The byte-level formats are in
`docs/FORMATS.md`, the threats and limits in `docs/THREAT_MODEL.md`.

## The parts

```
 Android phone                                     Chrome on a computer
 +-----------------------------------------+       +---------------------------+
 | Flutter app (Dart)                      |       | Extension (MV3)           |
 |  lock screen, vault, settings, sync     |       |  background service worker|
 |  autofill screen (second engine)        |       |  popup (unlock, list)     |
 +---------+-------------------------------+       |  content script (pages)   |
           | method channels                       +-------------+-------------+
 +---------v-------------------------------+                     |
 | Android side (Kotlin)                   |                     |
 |  autofill service, credential provider  |                     |
 |  unlock activity, session rules         |                     |
 +-----------------------------------------+                     |
           |                                                     |
           |           Google Drive, app-data folder             |
           +----------> one encrypted sync file <----------------+
```

Nothing runs on a server of ours. Google Drive holds one file that only the
two ends can decrypt.

## Flutter app (lib/)

- **AuthService** (`services/auth_service.dart`): unlock with PIN, password or
  fingerprint; the decoy; lockout and self-destruct; device settings.
- **VaultKeyService** (`services/vault_key_service.dart`): each vault's
  master key, sealed under a key derived from its secret by Argon2id, kept in
  Android's keystore-backed storage.
- **StorageService** (`services/storage_service.dart`) and **vault container**
  (`services/vault_container.dart`): both vaults in one file, `vault.rvc`, one
  encrypted slot each, written whole with the previous copy kept, guarded
  against an older copy being put back by sealed write counters.
- **VaultRepository** (`repository/vault_repository.dart`): what the screens
  use: entries, categories, search. The same in either vault.
- **ActivityLogService** (`services/activity_log_service.dart`): the vault's
  own log (inside its slot) and the device's security log (Hive, encrypted
  with a keystore key, nothing about vault contents).
- **Sync** (`sync/`): the engine merges this device's vault with the copy in
  Drive per entry, with tombstones for deletions and a generation counter
  against rollback; `sync_service.dart` runs it, and refuses in the decoy and
  in Strict Offline Mode before any network call.
- **Autofill screen** (`screens/autofill_screen.dart`): runs in a second
  Flutter engine started by the unlock activity. It unlocks, matches entries
  to the caller (`autofill/autofill_target.dart`), warns (look-alikes,
  unverified app pins, new sites), logs, and hands one login back.

## Android side (android/app/src/main/kotlin)

- **VaultAutofillService**: answers Android's autofill requests. Holds no key;
  offers "Unlock Ringer Vault", or the login kept for the next page of a
  sign-in (`NextStep`).
- **VaultCredentialService** (Android 14 and later): the Credential Manager
  provider. Offers an unlock action; the chosen login comes back as one
  entry, handed over through `CredentialHandoff`. `docs/CREDENTIAL_PROVIDER.md`.
- **AutofillUnlockActivity**: hosts the autofill screen for both surfaces and
  turns its answer into what each expects (a dataset, a sheet entry, a save
  response).
- **RequestIdentity**, **BrowserAllowlist**, **CredentialCaller**: who is
  asking. An app by its package and signing certificate; a web address only
  from a browser verified by its certificate; an unverified browser gets
  nothing.
- **VaultSession**: what the app tells the Android side: which vault opened
  (the fingerprint is offered only after the real vault's PIN), when a vault
  locks (everything kept for a fill is dropped), and whether the phone is
  short of memory.

## Extension (extension/)

- **Background** (`src/background.js`): unlocks the synced vault in memory
  (Argon2id in WebAssembly, `src/vendor/`), reads and writes the Drive file,
  matches entries to the tab's address (`src/vault/match.js`), fills through
  `src/fill.js`, and keeps logins waiting to be saved per tab, in session
  storage.
- **Content script** (`src/content/capture.js`): the list under a login field
  and the save bar, both in closed shadow roots; notices a login being sent.
  It can only ask the background about its own tab, and never holds a
  password except in the moment of a fill.
- **Popup** (`src/popup/`): unlock, the list for the current site with search
  over the whole vault, settings, import.

## Main flows

**Unlock (app).** The secret is tried against both vaults' sealed keys, always
both and always the same work, so the time taken does not say which opened
(`integration_test/unlock_timing_test.dart`).

**Fill on Android.** Login box focused, or the sign-in sheet shown; the
service offers an unlock; the autofill screen unlocks, matches, warns, logs;
one login goes back; the vault locks again.

**Save on Android.** Android offers saving a typed login; the save sheet
asks for nothing but a name and a category, and seals the login into the
inbox (`save_inbox.dart`) without opening the vault. The next unlock of
either vault takes its copy in (`StorageService.openVault` calls
`takeSaveInbox`), and the dashboard says what was added.

**The sheet.** The autofill and sign-in screen is a translucent activity;
Flutter draws a bottom sheet over the app being signed in to, which stays in
view behind it.

**Sync.** Read the Drive copy, check its generation, merge per entry, write
back only if nobody wrote in between, otherwise start again.

**Fill in Chrome.** The list under the field, or the popup; only entries linked
to the tab's exact site fill with one click; others ask first and, from the
list, are linked to the site.

**Save in Chrome.** A sent form's login waits for the next page; a new login
is offered at once, an update only once the sign-in is seen to succeed.

## Where each secret lives

| What | Where | Protected by |
|---|---|---|
| Vault entries | `vault.rvc`, the vault's slot | AES-256-GCM, master key |
| Master keys | Secure storage | Sealed under Argon2id(secret) |
| Write counters | Secure storage | Sealed with the vault's keys |
| Security log | Hive file | AES, keystore-held key |
| Drive copy | Google Drive app-data | Sync passphrase, Argon2id 64 MiB |
| Extension's copy | `chrome.storage.local` | The same encryption as Drive |
| Login kept for a next page | App memory, two minutes | Never written |
| Login waiting to be saved (extension) | Session storage, three minutes | Gone when the browser closes |
