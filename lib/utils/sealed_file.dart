import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// The encrypted file shared by exported backups, Google Drive sync and the
/// browser extension (extension/src/vault/format.js reads and writes it too).
///
/// Version 1, still read:
///
///     base64( salt(16) || nonce(12) || mac(16) || ciphertext )
///     key = PBKDF2-HMAC-SHA256(passphrase, salt, 100000, 256 bits)
///
/// Version 2, still read, and written by the web build of the app:
///
///     base64( "RVLT" || 0x02 || kdf || iterations(u32, big-endian)
///             || salt(16) || nonce(12) || mac(16) || ciphertext )
///     kdf 0x01 = PBKDF2-HMAC-SHA256
///
/// with the first 10 bytes (magic to iterations) bound to the ciphertext as
/// AES-GCM additional data, so the settings cannot be altered unnoticed.
///
/// Version 3, written from now on:
///
///     base64( "RVLT" || 0x03 || kdf || memory KiB(u32) || passes(u32)
///             || lanes(u8) || salt(16) || nonce(12) || mac(16)
///             || ciphertext )
///     kdf 0x02 = Argon2id, 32-byte output
///
/// with the first 15 bytes bound as additional data in the same way.
///
/// Why: the file sits in Google Drive, where a stolen copy can be attacked
/// offline, and PBKDF2 at any count is cheap to run on graphics cards.
/// Argon2id needs memory for every guess, which is what makes those cards
/// slow. 64 MiB, 3 passes, 1 lane: twice the local vault's memory, because
/// this file can be taken away and guessed at offline while its key is
/// derived about once a session (about a second on a mid-range phone, a
/// sixth of one in the extension). Recorded rather than implied, so they
/// can be raised later without breaking files already written. The extension runs the same Argon2id
/// through WebAssembly (extension/src/vendor), and a shared test vector
/// keeps the two in step. The web build of the app stays on version 2:
/// pure-Dart Argon2id freezes a browser tab for over 20 seconds.

const int sealedIterationsV1 = 100000;

/// What new files are written with.
const int sealedIterationsCurrent = 600000;

/// Refused when reading, so a crafted file cannot make the app derive a key
/// for minutes (too many) or settle for a weak one (too few).
const int _maxIterations = 10000000;

/// Argon2id for new files (see the top of this file).
const int sealedMemoryKib = 64 * 1024;
const int sealedPasses = 3;
const int sealedLanes = 1;

/// Refused when reading, for the same reason as [_maxIterations]: a
/// crafted file must not make the app run out of memory or settle for a
/// weak key. A file is read before it can be authenticated, so these are
/// what a stranger's file could demand: 128 MiB and 6 passes are twice what
/// Ringer Vault writes, and within what even a low-end phone can give.
const int _minMemoryKib = 19 * 1024;
const int _maxMemoryKib = 128 * 1024;
const int _maxPasses = 6;
const int _maxLanes = 8;

const int _saltBytes = 16;
const int _nonceBytes = 12;
const int _macBytes = 16;
const List<int> _magic = [0x52, 0x56, 0x4C, 0x54]; // "RVLT"
const int _v2HeaderBytes = 10;
const int _v3HeaderBytes = 15;
const int _kdfPbkdf2Sha256 = 0x01;
const int _kdfArgon2id = 0x02;

class SealedFormatError implements Exception {
  final String message;
  const SealedFormatError([this.message = 'This is not a Ringer Vault file.']);

  @override
  String toString() => message;
}

/// How a file's key is made, and which layout it is written in.
class SealParams {
  final int version;
  final List<int> salt;

  /// PBKDF2's count for versions 1 and 2; Argon2id's passes for version 3.
  final int iterations;

  /// Argon2id's memory and lanes; 0 for versions 1 and 2.
  final int memoryKib;
  final int lanes;

  const SealParams({
    required this.version,
    required this.salt,
    required this.iterations,
    this.memoryKib = 0,
    this.lanes = 0,
  });

  /// What the app writes: version 3 at the current settings, or version 2
  /// in the web build (see the top of this file). The app holds the
  /// passphrase, so it can always derive this key.
  factory SealParams.current(List<int> salt, {bool web = kIsWeb}) => web
      ? SealParams(version: 2, salt: salt, iterations: sealedIterationsCurrent)
      : SealParams(
          version: 3,
          salt: salt,
          iterations: sealedPasses,
          memoryKib: sealedMemoryKib,
          lanes: sealedLanes,
        );

  static SealParams fresh() => SealParams.current(randomBytes(_saltBytes));

  /// Identifies a derived key: the same salt and settings give the same key.
  String get id => '${base64Encode(salt)}:$version:$iterations:$memoryKib:$lanes';
}


/// A sealed file taken apart.
class SealedParts {
  final SealParams params;
  final List<int> nonce;
  final List<int> mac;
  final List<int> cipherText;

  /// The header bound as AES-GCM additional data; empty for version 1.
  final List<int> aad;

  const SealedParts(this.params, this.nonce, this.mac, this.cipherText, this.aad);
}

List<int> randomBytes(int n) {
  final rng = Random.secure();
  return List<int>.generate(n, (_) => rng.nextInt(256));
}

/// The version a file with the "RVLT" magic declares, or 1 without it.
int _versionOf(List<int> b) =>
    b.length > _v2HeaderBytes &&
        b[0] == _magic[0] && b[1] == _magic[1] && b[2] == _magic[2] && b[3] == _magic[3]
    ? b[4]
    : 1;

/// Splits decoded bytes of either version. Throws [SealedFormatError].
SealedParts splitSealed(List<int> bytes) {
  var at = 0;
  final version = _versionOf(bytes);
  var iterations = sealedIterationsV1;
  var memoryKib = 0;
  var lanes = 0;
  var aad = const <int>[];
  int u32(int from) => ByteData.sublistView(Uint8List.fromList(bytes.sublist(from, from + 4))).getUint32(0);
  const newer = SealedFormatError('This file was made by a newer version of Ringer Vault.');
  switch (version) {
    case 1:
      break;
    case 2:
      if (bytes[5] != _kdfPbkdf2Sha256) throw newer;
      iterations = u32(6);
      if (iterations < sealedIterationsV1 || iterations > _maxIterations) {
        throw const SealedFormatError();
      }
      aad = bytes.sublist(0, _v2HeaderBytes);
      at = _v2HeaderBytes;
    case 3:
      if (bytes.length <= _v3HeaderBytes) throw const SealedFormatError();
      if (bytes[5] != _kdfArgon2id) throw newer;
      memoryKib = u32(6);
      iterations = u32(10);
      lanes = bytes[14];
      if (memoryKib < _minMemoryKib ||
          memoryKib > _maxMemoryKib ||
          iterations < 1 ||
          iterations > _maxPasses ||
          lanes < 1 ||
          lanes > _maxLanes ||
          memoryKib < 8 * lanes) {
        throw const SealedFormatError();
      }
      aad = bytes.sublist(0, _v3HeaderBytes);
      at = _v3HeaderBytes;
    default:
      throw newer;
  }
  if (bytes.length <= at + _saltBytes + _nonceBytes + _macBytes) {
    throw const SealedFormatError();
  }
  final salt = bytes.sublist(at, at + _saltBytes);
  at += _saltBytes;
  final nonce = bytes.sublist(at, at + _nonceBytes);
  at += _nonceBytes;
  final mac = bytes.sublist(at, at + _macBytes);
  at += _macBytes;
  return SealedParts(
    SealParams(
      version: version,
      salt: salt,
      iterations: iterations,
      memoryKib: memoryKib,
      lanes: lanes,
    ),
    nonce,
    mac,
    bytes.sublist(at),
    aad,
  );
}

/// [splitSealed] for the base64 text form.
SealedParts splitSealedText(String text) {
  final List<int> bytes;
  try {
    bytes = base64Decode(text.trim());
  } on FormatException {
    throw const SealedFormatError();
  }
  return splitSealed(bytes);
}

/// The key a passphrase makes with [params]. Slow on purpose: run it on a
/// background isolate.
Future<List<int>> deriveSealKey(String passphrase, SealParams params) async {
  final SecretKey key;
  if (params.version == 3) {
    key = await Argon2id(
      memory: params.memoryKib,
      iterations: params.iterations,
      parallelism: params.lanes,
      hashLength: 32,
    ).deriveKeyFromPassword(password: passphrase, nonce: params.salt);
  } else {
    key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: params.iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: passphrase, nonce: params.salt);
  }
  return key.extractBytes();
}

List<int> _header(SealParams params) {
  final u32 = ByteData(8);
  if (params.version == 3) {
    u32
      ..setUint32(0, params.memoryKib)
      ..setUint32(4, params.iterations);
    return [
      ..._magic, 0x03, _kdfArgon2id, ...u32.buffer.asUint8List(), params.lanes,
    ];
  }
  u32.setUint32(0, params.iterations);
  return [..._magic, 0x02, _kdfPbkdf2Sha256, ...u32.buffer.asUint8List(0, 4)];
}

/// Seals [plain] with [key] in the layout [params] names. The app writes
/// version 3 (version 2 on web); version 1 exists here so tests can make
/// old files.
Future<String> sealWithKey(List<int> plain, List<int> key, SealParams params) async {
  final aad = params.version == 1 ? const <int>[] : _header(params);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKey(key),
    aad: aad,
  );
  final out = BytesBuilder(copy: false)
    ..add(aad)
    ..add(params.salt)
    ..add(box.nonce)
    ..add(box.mac.bytes)
    ..add(box.cipherText);
  return base64Encode(out.takeBytes());
}

/// Opens [parts] with [key], or null when the key does not fit (a wrong
/// passphrase and an altered file look the same, on purpose).
Future<List<int>?> openWithKey(SealedParts parts, List<int> key) async {
  try {
    return await AesGcm.with256bits().decrypt(
      SecretBox(parts.cipherText, nonce: parts.nonce, mac: Mac(parts.mac)),
      secretKey: SecretKey(key),
      aad: parts.aad,
    );
  } on SecretBoxAuthenticationError {
    return null;
  }
}
