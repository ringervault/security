import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

/// Thrown when a stored value does not carry a valid tag: the vault file was
/// changed by something other than this app.
class VaultTamperedError extends Error {
  @override
  String toString() =>
      'The vault file was changed outside Ringer Vault, so it was not opened.';
}

/// Hive encryption that also detects tampering.
///
/// Hive's own HiveAesCipher is AES-256-CBC with only a CRC checksum, which
/// catches accidents but not deliberate edits: someone able to write the
/// file could alter ciphertext and the app would decrypt whatever came out.
/// This keeps the same AES-256-CBC (Hive needs a synchronous cipher, which
/// rules out the async AES-GCM of the cryptography package) and adds
/// encrypt-then-MAC: every stored value is followed by an HMAC-SHA256 tag
/// over its IV and ciphertext, checked in constant time before anything is
/// decrypted.
///
/// The encryption key and the tag key are both derived from the vault's
/// master key with HMAC-SHA256 under different labels, so neither key is
/// used for two jobs.
///
/// What it does not cover: Hive stores each entry's ID (the box key) in the
/// clear and outside what the cipher sees, and a tag cannot stop an old,
/// genuine value being put back, or a value being removed. Those need write
/// access to the app's private storage, which Android gives no other app.
class VaultCipher implements HiveCipher {
  static const int _tagBytes = 32;

  late final HiveAesCipher _aes;
  late final Hmac _mac;
  late final int _keyCrc;

  VaultCipher(List<int> masterKey) {
    if (masterKey.length != 32) {
      throw ArgumentError('The vault key has to be 32 bytes.');
    }
    final root = Hmac(sha256, masterKey);
    final encKey = root.convert(utf8.encode('ringer-vault/hive/encrypt/v2')).bytes;
    final macKey = root.convert(utf8.encode('ringer-vault/hive/mac/v2')).bytes;
    _aes = HiveAesCipher(encKey);
    _mac = Hmac(sha256, macKey);
    // Seeds Hive's per-frame CRC. Different from HiveAesCipher's, so a file
    // written by one is never read as the other's.
    final id = sha256.convert([...encKey, ...macKey]).bytes;
    _keyCrc = ByteData.sublistView(Uint8List.fromList(id)).getUint32(0);
  }

  @override
  int calculateKeyCrc() => _keyCrc;

  @override
  int maxEncryptedSize(Uint8List inp) => _aes.maxEncryptedSize(inp) + _tagBytes;

  @override
  int encrypt(Uint8List inp, int inpOff, int inpLength, Uint8List out, int outOff) {
    final length = _aes.encrypt(inp, inpOff, inpLength, out, outOff);
    final tag = _mac.convert(Uint8List.sublistView(out, outOff, outOff + length)).bytes;
    out.setRange(outOff + length, outOff + length + _tagBytes, tag);
    return length + _tagBytes;
  }

  @override
  int decrypt(Uint8List inp, int inpOff, int inpLength, Uint8List out, int outOff) {
    // At least a 16-byte IV, one 16-byte block, and the tag.
    if (inpLength < 32 + _tagBytes) throw VaultTamperedError();
    final body = inpLength - _tagBytes;
    final expected = _mac.convert(Uint8List.sublistView(inp, inpOff, inpOff + body)).bytes;
    var diff = 0;
    for (var i = 0; i < _tagBytes; i++) {
      diff |= expected[i] ^ inp[inpOff + body + i];
    }
    if (diff != 0) throw VaultTamperedError();
    return _aes.decrypt(inp, inpOff, body, out, outOff);
  }
}
