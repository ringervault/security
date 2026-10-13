import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/utils/sealed_file.dart';

const passphrase = 'correct horse battery staple';

/// A file in the old layout, as every build before version 2 wrote.
Future<String> v1File(List<int> plain) async {
  final params = SealParams(version: 1, salt: randomBytes(16), iterations: sealedIterationsV1);
  return sealWithKey(plain, await deriveSealKey(passphrase, params), params);
}

void main() {
  test('new files are version 3, Argon2id, with the header bound', () async {
    final text = await SyncCipher(passphrase).encrypt(utf8.encode('hello'));
    final bytes = base64Decode(text);
    expect(utf8.decode(bytes.sublist(0, 4)), 'RVLT');
    expect(bytes[4], 3);
    final parts = splitSealedText(text);
    expect(parts.params.memoryKib, sealedMemoryKib);
    expect(parts.params.iterations, sealedPasses);
    expect(parts.aad, hasLength(15));
  });

  test('a version 2 file still opens, and the next write upgrades it', () async {
    final params = SealParams(version: 2, salt: randomBytes(16), iterations: sealedIterationsCurrent);
    final old = await sealWithKey(
        utf8.encode('from PBKDF2'), await deriveSealKey(passphrase, params), params);
    final cipher = SyncCipher(passphrase);
    expect(utf8.decode(await cipher.decrypt(old)), 'from PBKDF2');
    expect(splitSealedText(await cipher.encrypt(utf8.encode('next'))).params.version, 3);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a version 1 file still opens, and the next write upgrades it', () async {
    final old = await v1File(utf8.encode('from an older build'));
    expect(splitSealedText(old).params.version, 1);

    final cipher = SyncCipher(passphrase);
    expect(utf8.decode(await cipher.decrypt(old)), 'from an older build');

    final rewritten = await cipher.encrypt(utf8.encode('next write'));
    final parts = splitSealedText(rewritten);
    expect(parts.params.version, 3);
    expect(utf8.decode(await SyncCipher(passphrase).decrypt(rewritten)), 'next write');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('lowering the recorded cost makes the file unreadable, never weaker', () async {
    final text = await SyncCipher(passphrase).encrypt(utf8.encode('x'));
    final bytes = base64Decode(text);
    bytes[13] = 1; // one pass instead of three
    await expectLater(
      SyncCipher(passphrase).decrypt(base64Encode(bytes)),
      throwsA(isA<SyncCipherError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an absurd count is refused before any key is derived', () {
    final bytes = [...utf8.encode('RVLT'), 2, 1, 0xFF, 0xFF, 0xFF, 0xFF, ...List.filled(60, 1)];
    expect(() => splitSealed(bytes), throwsA(isA<SealedFormatError>()));
  });

  test('a file from a newer key-derivation scheme is named as such', () {
    final bytes = [...utf8.encode('RVLT'), 2, 9, 0, 9, 0x27, 0xC0, ...List.filled(60, 1)];
    expect(
      () => splitSealed(bytes),
      throwsA(isA<SealedFormatError>().having((e) => e.message, 'message', contains('newer version'))),
    );
  });

  group('the web build, which can only write version 2', () {
    test('never writes over a version 3 file it has read', () async {
      final v3 = await SyncCipher(passphrase).encrypt(utf8.encode('strong'));
      final web = SyncCipher.forWeb(passphrase);
      expect(utf8.decode(await web.decrypt(v3)), 'strong', reason: 'reading is fine');
      await expectLater(web.encrypt(utf8.encode('weaker')), throwsA(isA<SyncDowngradeRefused>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('keeps a version 2 file in version 2', () async {
      final params = SealParams(version: 2, salt: randomBytes(16), iterations: sealedIterationsCurrent);
      final v2 = await sealWithKey(utf8.encode('old'), await deriveSealKey(passphrase, params), params);
      final web = SyncCipher.forWeb(passphrase);
      await web.decrypt(v2);
      expect(splitSealedText(await web.encrypt(utf8.encode('next'))).params.version, 2);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
