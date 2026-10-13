# Ringer Vault extension: security modules

These are the parts of the Ringer Vault Chrome extension that protect your
data, with their tests. They are published for review only. This is not the
whole extension: its manifest, background service worker, page script,
pop-up, Touch ID window, icons and Google Drive access are not included, so
it cannot be loaded into Chrome from here. Install Ringer Vault from the
Chrome Web Store.

| File | What it does |
|---|---|
| `src/vault/format.js` | The sealed-file format shared with the app: Argon2id (hash-wasm, pinned by SHA-256) and AES-256-GCM |
| `src/vault/rollback.js` | Refuses an older copy of the synced vault put back in Drive |
| `src/vault/quick.js` | Quick unlock: a PIN kept in memory only, and Touch ID or Windows Hello through WebAuthn PRF |
| `src/vault/host.js`, `match.js` | Which saved logins belong to the page's exact address |
| `src/vault/lookalike.js`, `punycode.js`, `known_sites.js` | Look-alike website warnings |
| `src/vault/domain_age.js` | How new a website is (optional check) |
| `src/vault/save.js`, `save_bar.js` | When a login is offered for saving, and how it is written with its previous passwords |
| `src/vault/known.js` | Keyed tags of the accounts the vault holds, never passwords |
| `src/vault/passphrase.js` | Sync passphrase strength |
| `src/fill.js` | Filling a form, and putting a fill back if another password manager overwrites it |

Run the tests with Node 20 or later:

```bash
npm test
```

`../test/extension_interchange_test.dart` runs `test/*_cli.mjs` from Dart to
prove the app and the extension read and write each other's files.
