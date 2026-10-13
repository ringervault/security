/// The one file both vaults live in on the phone.
///
///     "RVC1" || version(1) || reserved(3)
///     || slot 0 (the real vault) || slot 1 (the decoy)
///
/// Both slots are always there and always the same size, so the file says
/// nothing about how many entries either vault holds or whether a decoy
/// exists. A slot is:
///
///     nonce(12) || AES-256-GCM(plaintext) || tag(16) || random filler
///
/// The plaintext is the whole vault as JSON (entries, deletion records and
/// its activity log), length-prefixed and zero-padded to a size bucket
/// (64 KiB, 128 KiB, 256 KiB, 512 KiB, 1 MiB, then whole MiB), so its exact
/// size is hidden even from someone comparing two copies of the file. A
/// slot is as large as the larger of the two vaults' buckets; the smaller
/// one's ciphertext is followed by random bytes, which look the same as
/// ciphertext. With no decoy, slot 1 is random bytes from end to end.
///
/// The slot numbers are fixed rather than random. That gives nothing away:
/// nobody without a key can tell an empty decoy slot from a full one, and
/// it means neither vault ever needs to know where the other one is.
///
/// AES-GCM covers the whole vault at once, so a removed or altered entry is
/// caught, not only an altered value (which is all the per-value tags of the
/// Hive files it replaces could catch). The magic, version and slot number
/// are bound to it as additional data, so the slots cannot be swapped.
/// Putting back an older genuine copy of the file is caught by the write
/// count each slot carries, checked against a copy kept in secure storage
/// (see StorageService).
///
/// A vault finds its own slot's length by trying every bucket up to the
/// slot's size: nothing outside the encryption records it. Every bucket is
/// tried even after one fits, so opening either vault in a given file costs
/// the same, however much each holds.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

const String containerFileName = 'vault.rvc';
const int realSlot = 0;
const int decoySlot = 1;

const List<int> _magic = [0x52, 0x56, 0x43, 0x31]; // "RVC1"
const int _version = 1;
const int headerBytes = 8;
const int _nonceBytes = 12;
const int _tagBytes = 16;
const int _lengthBytes = 4;

/// The size buckets a slot can have, smallest first: 64 KiB doubling to
/// 1 MiB, then every whole MiB up to [maxSlotBytes].
const int minSlotBytes = 64 * 1024;
const int maxSlotBytes = 64 * 1024 * 1024;

Iterable<int> slotBuckets() sync* {
  for (var b = minSlotBytes; b < 1024 * 1024; b *= 2) {
    yield b;
  }
  for (var b = 1024 * 1024; b <= maxSlotBytes; b += 1024 * 1024) {
    yield b;
  }
}

/// The smallest bucket a vault of [plainLength] bytes of JSON fits in.
int slotSizeFor(int plainLength) {
  for (final b in slotBuckets()) {
    if (b - _nonceBytes - _tagBytes - _lengthBytes >= plainLength) return b;
  }
  throw const ContainerError('The vault is too large to store.');
}

class ContainerError implements Exception {
  final String message;
  const ContainerError(this.message);

  @override
  String toString() => message;
}

/// The keys a vault's master key gives for the container: one for its slot,
/// one for its write count. Neither key is used for anything else.
class SlotKeys {
  final List<int> slot;
  final List<int> count;

  SlotKeys(List<int> masterKey)
      : slot = _label(masterKey, 'ringer-vault/container/slot/v1'),
        count = _label(masterKey, 'ringer-vault/container/count/v1');

  /// Keys already derived, as handed to a background isolate.
  const SlotKeys.fromParts({required this.slot, required this.count});

  static List<int> _label(List<int> key, String label) =>
      crypto.Hmac(crypto.sha256, key).convert(utf8.encode(label)).bytes;
}

List<int> _aad(int slot) => [..._magic, _version, 0, 0, 0, slot];

Uint8List noise(int n) {
  final out = Uint8List(n);
  final words = out.buffer.asUint32List(0, n ~/ 4);
  final rng = Random.secure();
  for (var i = 0; i < words.length; i++) {
    words[i] = rng.nextInt(1 << 32);
  }
  for (var i = words.length * 4; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// [vault] sealed into a slot of [slotSize] bytes (at least its own bucket).
Future<Uint8List> sealSlot(
  Map<String, dynamic> vault,
  SlotKeys keys,
  int slot, {
  int slotSize = 0,
}) async {
  final json = utf8.encode(jsonEncode(vault));
  final own = slotSizeFor(json.length);
  final size = max(own, slotSize);

  final plain = Uint8List(own - _nonceBytes - _tagBytes);
  ByteData.sublistView(plain).setUint32(0, json.length);
  plain.setRange(_lengthBytes, _lengthBytes + json.length, json);

  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKey(keys.slot),
    aad: _aad(slot),
  );
  return Uint8List(size)
    ..setRange(0, _nonceBytes, box.nonce)
    ..setRange(_nonceBytes, own - _tagBytes, box.cipherText)
    ..setRange(own - _tagBytes, own, box.mac.bytes)
    ..setRange(own, size, noise(size - own));
}

/// The vault in [bytes] (one slot), or null when [keys] do not open it:
/// another vault's slot, random filler, or a slot altered by anyone.
Future<Map<String, dynamic>?> openSlot(Uint8List bytes, SlotKeys keys, int slot) async {
  final algorithm = AesGcm.with256bits();
  final nonce = bytes.sublist(0, _nonceBytes);
  Map<String, dynamic>? found;
  for (final b in slotBuckets()) {
    if (b > bytes.length) break;
    if (found != null) {
      // The same work as an attempt that fails, so the time taken does not
      // say which bucket fitted.
      try {
        await algorithm.decrypt(
          SecretBox(
            bytes.sublist(_nonceBytes, b - _tagBytes),
            nonce: nonce,
            mac: Mac(bytes.sublist(b - _tagBytes, b)),
          ),
          secretKey: SecretKey(keys.slot),
          aad: _aad(slot),
        );
      } on SecretBoxAuthenticationError {
        // Expected.
      }
      continue;
    }
    try {
      final plain = await algorithm.decrypt(
        SecretBox(
          bytes.sublist(_nonceBytes, b - _tagBytes),
          nonce: nonce,
          mac: Mac(bytes.sublist(b - _tagBytes, b)),
        ),
        secretKey: SecretKey(keys.slot),
        aad: _aad(slot),
      );
      final p = Uint8List.fromList(plain);
      final length = ByteData.sublistView(p).getUint32(0);
      if (length > p.length - _lengthBytes) return null;
      final decoded = jsonDecode(utf8.decode(p.sublist(_lengthBytes, _lengthBytes + length)));
      if (decoded is! Map<String, dynamic>) return null;
      found = decoded;
    } on SecretBoxAuthenticationError {
      continue;
    }
  }
  return found;
}

/// The two slots of a container file. Throws [ContainerError] for anything
/// that is not one.
(Uint8List, Uint8List) splitContainer(Uint8List file) {
  if (file.length < headerBytes + 2 * minSlotBytes ||
      (file.length - headerBytes).isOdd ||
      file[0] != _magic[0] || file[1] != _magic[1] ||
      file[2] != _magic[2] || file[3] != _magic[3]) {
    throw const ContainerError('The vault file is not one Ringer Vault wrote.');
  }
  if (file[4] != _version) {
    throw const ContainerError('The vault file was written by a newer version of Ringer Vault.');
  }
  final size = (file.length - headerBytes) ~/ 2;
  return (
    Uint8List.sublistView(file, headerBytes, headerBytes + size),
    Uint8List.sublistView(file, headerBytes + size),
  );
}

/// A container with [own] in [slot], and the other slot carried over from
/// [existing] (or random, when there is no file yet). The other slot is
/// copied byte for byte, since this vault cannot read it, and lengthened
/// with random bytes if [own] needs a bigger slot. Slots never shrink: the
/// other vault's true size is unknown here.
Uint8List assemble({Uint8List? existing, required Uint8List own, required int slot}) {
  Uint8List? other;
  if (existing != null) {
    final (a, b) = splitContainer(existing);
    other = slot == realSlot ? b : a;
  }
  final size = max(own.length, other?.length ?? 0);
  Uint8List fit(Uint8List? s) {
    if (s == null) return noise(size);
    if (s.length == size) return s;
    return Uint8List(size)
      ..setRange(0, s.length, s)
      ..setRange(s.length, size, noise(size - s.length));
  }

  final mine = fit(own);
  final theirs = fit(other);
  return Uint8List(headerBytes + 2 * size)
    ..setRange(0, 4, _magic)
    ..[4] = _version
    ..setRange(headerBytes, headerBytes + size, slot == realSlot ? mine : theirs)
    ..setRange(headerBytes + size, headerBytes + 2 * size, slot == realSlot ? theirs : mine);
}

/// The write count, sealed for keeping in secure storage under the slot's
/// own name: 36 bytes either way, so an unused slot's random stand-in looks
/// the same as a real one.
Future<String> sealCount(int count, SlotKeys keys, int slot) async {
  final plain = ByteData(8)..setUint64(0, count);
  final box = await AesGcm.with256bits().encrypt(
    plain.buffer.asUint8List(),
    secretKey: SecretKey(keys.count),
    aad: _aad(slot),
  );
  return base64Encode(box.concatenation());
}

/// A stand-in for a slot nothing has written to.
String unusedCount() => base64Encode(noise(_nonceBytes + 8 + _tagBytes));

/// The write count in [sealed], or null when it is not this vault's (a
/// stand-in, or another key's).
Future<int?> openCount(String? sealed, SlotKeys keys, int slot) async {
  if (sealed == null) return null;
  try {
    final algorithm = AesGcm.with256bits();
    final plain = await algorithm.decrypt(
      SecretBox.fromConcatenation(
        base64Decode(sealed),
        nonceLength: _nonceBytes,
        macLength: _tagBytes,
      ),
      secretKey: SecretKey(keys.count),
      aad: _aad(slot),
    );
    return ByteData.sublistView(Uint8List.fromList(plain)).getUint64(0);
  } catch (_) {
    return null;
  }
}
