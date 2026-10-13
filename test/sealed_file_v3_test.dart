import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/utils/sealed_file.dart';

/// Version 3 sealed files: Argon2id, shared with the browser extension
/// through test/fixtures/argon2id_vector.json.
void main() {
  final vector = jsonDecode(
    File('test/fixtures/argon2id_vector.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final password = vector['password'] as String;
  List<int> hex(String s) => [
        for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
      ];

  test('Argon2id gives the bytes the extension gives', () async {
    final key = await deriveSealKey(
      password,
      SealParams(
        version: 3,
        salt: hex(vector['saltHex'] as String),
        iterations: vector['passes'] as int,
        memoryKib: vector['memoryKib'] as int,
        lanes: vector['lanes'] as int,
      ),
    );
    expect(key, hex(vector['keyHex'] as String));
  });

  test('new files are version 3 at 64 MiB, twice the local vault', () {
    final params = SealParams.current(randomBytes(16), web: false);
    expect(params.version, 3);
    expect((params.memoryKib, params.iterations, params.lanes), (64 * 1024, 3, 1));
    expect(SealParams.current(randomBytes(16), web: true).version, 2,
        reason: 'pure-Dart Argon2id would freeze a browser tab');
  });

  test('a file the extension sealed opens here', () async {
    final parts = splitSealedText(vector['sealedByExtension'] as String);
    expect(parts.params.version, 3);
    final plain = await openWithKey(parts, await deriveSealKey(password, parts.params));
    expect(jsonDecode(utf8.decode(plain!))['format'], 'ringer-vault-sync');
  });

  test('a file sealed here opens here, and its settings cannot be changed', () async {
    final params = SealParams.current(randomBytes(16), web: false);
    final key = await deriveSealKey(password, params);
    final text = await sealWithKey(utf8.encode('{"ok":true}'), key, params);
    final parts = splitSealedText(text);
    expect(await openWithKey(parts, key), utf8.encode('{"ok":true}'));

    // One more pass in the header: the key no longer fits, and the header
    // is checked as part of the ciphertext anyway.
    final bytes = base64Decode(text);
    bytes[13] += 1;
    final altered = splitSealed(bytes);
    expect(await openWithKey(altered, key), isNull);
  });

  test('settings that are too weak or too costly are refused unread', () {
    List<int> withHeader(int memoryKib, int passes, int lanes) {
      final b = base64Decode(vector['sealedByExtension'] as String);
      final d = b.buffer.asByteData();
      d.setUint32(6, memoryKib);
      d.setUint32(10, passes);
      b[14] = lanes;
      return b;
    }

    for (final (m, t, p) in [
      (1024, 3, 1), // too little memory
      (4 * 1024 * 1024, 3, 1), // 4 GiB
      (1024 * 1024, 3, 1), // 1 GiB: enough to end the app on a phone
      (512 * 1024, 3, 1),
      (32768, 11, 1),
      (32768, 20, 1),
      (32768, 0, 1),
      (32768, 1000, 1),
      (32768, 3, 0),
      (32768, 3, 200),
    ]) {
      expect(() => splitSealed(withHeader(m, t, p)), throwsA(isA<SealedFormatError>()),
          reason: '$m KiB, $t passes, $p lanes');
    }
    // The most a file may ask for is still read.
    expect(() => splitSealed(withHeader(256 * 1024, 10, 1)), returnsNormally);
  });

  test('a later version or another key function says it is newer', () {
    final b = base64Decode(vector['sealedByExtension'] as String);
    expect(() => splitSealed([...b.sublist(0, 4), 4, ...b.sublist(5)]),
        throwsA(predicate((e) => '$e'.contains('newer'))));
    expect(() => splitSealed([...b.sublist(0, 5), 9, ...b.sublist(6)]),
        throwsA(predicate((e) => '$e'.contains('newer'))));
  });

  test('the file the app sealed for the fixture still opens', () async {
    final parts = splitSealedText(vector['sealedByApp'] as String);
    final plain = await openWithKey(parts, await deriveSealKey(password, parts.params));
    expect(jsonDecode(utf8.decode(plain!))['format'], 'ringer-vault-sync');
  });
}
