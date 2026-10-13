import 'package:flutter/foundation.dart';
import 'package:ringer_vault/utils/sealed_file.dart';

/// Encrypts and decrypts the sync file, without paying for the slow part more
/// than once.
///
/// The format is that of an exported backup, which the browser extension
/// also reads: see lib/utils/sealed_file.dart and docs/FORMATS.md. Versions
/// 1, 2 and 3 are read; this writes version 3 (Argon2id, 64 MiB) on the
/// phone and version 2 (PBKDF2-SHA256) on the web build, so a vault synced
/// by an older build is upgraded by its next write here.
///
/// Deriving the key is deliberately expensive, and doing it on every read
/// and every write was most of the time a sync took. Two things remove it:
///
/// Keys are remembered per salt and iteration count for as long as this
/// object lives, which is one unlocked session. They are dropped by
/// [forget] when the vault locks.
///
/// Writes reuse the salt of the last file read rather than choosing a new
/// one. Every device therefore settles on the same salt, and after the first
/// sync of a session no device derives a key again. Each write still gets a
/// fresh random nonce, which is what AES-GCM needs to stay safe under one
/// key.
class SyncCipher {
  SyncCipher(this._passphrase);

  SyncCipher.forWeb(this._passphrase) : _web = true;

  final String _passphrase;
  final Map<String, List<int>> _keys = {};
  List<int>? _salt;
  bool _web = kIsWeb;

  /// The highest format version read this session.
  int _newestRead = 0;

  /// Whether a key is already derived, so the next operation will be quick.
  bool get isWarm => _keys.isNotEmpty;

  // The work itself (AES-GCM over the whole vault, and base64 both ways)
  // runs on a background isolate. On Android the app's Dart code shares the
  // thread that handles touches, and doing it there froze the screen for
  // seconds at "Unlocking backup", long enough for Android to report the app
  // as not responding and close it.

  Future<String> encrypt(List<int> plain) async {
    // The web build writes version 2 (see sealed_file.dart). Over a file
    // already in version 3 that would quietly weaken the copy in Drive, the
    // one an attacker is likeliest to get, so it is refused instead.
    if (_web && _newestRead >= 3) throw const SyncDowngradeRefused();
    final params = SealParams.current(_salt ??= randomBytes(16), web: _web);
    final key = await _keyFor(params);
    return compute(_seal, (key, params, Uint8List.fromList(plain)));
  }

  /// Throws [SyncCipherError] if the content is not in the format, or if the
  /// passphrase does not open it, which AES-GCM makes indistinguishable from
  /// the file having been altered.
  Future<List<int>> decrypt(String content) async {
    final SealedParts parts;
    try {
      parts = splitSealedText(content);
    } on SealedFormatError {
      throw const SyncCipherError();
    }
    final key = await _keyFor(parts.params);
    final plain = await compute(_open, (parts, key));
    if (plain == null) {
      // A wrong passphrase derives a useless key; keeping it would only
      // make the next attempt with the right one look up the wrong entry.
      _keys.remove(parts.params.id);
      throw const SyncCipherError();
    }
    // Adopt this salt, so the next write lets every device keep its key.
    _salt = parts.params.salt;
    if (parts.params.version > _newestRead) _newestRead = parts.params.version;
    return plain;
  }

  /// Drops every derived key. Called when the vault locks.
  void forget() {
    _keys.clear();
    _salt = null;
  }

  Future<List<int>> _keyFor(SealParams params) async {
    final known = _keys[params.id];
    if (known != null) return known;

    // On a background isolate: this takes long enough to freeze a progress
    // animation if it ran on the one drawing the screen.
    final bytes = await compute(_derive, (_passphrase, params));
    _keys[params.id] = bytes;
    return bytes;
  }
}

Future<List<int>> _derive((String, SealParams) args) =>
    deriveSealKey(args.$1, args.$2);

/// Seals [plain] in the shared layout. Runs on a background isolate.
Future<String> _seal((List<int>, SealParams, Uint8List) args) =>
    sealWithKey(args.$3, args.$1, args.$2);

/// Opens a sealed file, or returns null when the key does not open it.
/// Runs on a background isolate.
Future<List<int>?> _open((SealedParts, List<int>) args) =>
    openWithKey(args.$1, args.$2);

/// The web build will not replace a version 3 sync file with version 2.
class SyncDowngradeRefused implements Exception {
  const SyncDowngradeRefused();

  @override
  String toString() =>
      'Your backup uses stronger encryption than this browser version of '
      'Ringer Vault can write, so changes made here were not uploaded. They '
      'are kept on this device. Sync from the phone app, or the browser '
      'extension, to send them.';
}

class SyncCipherError implements Exception {
  const SyncCipherError();
}
