import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/utils/common_words.g.dart';
import 'package:ringer_vault/utils/passphrase_strength.dart';
import 'package:ringer_vault/utils/password_generator.dart';

/// The sync passphrase's strength, against the cases the extension's tests
/// run too.
void main() {
  final fixture = jsonDecode(File('test/fixtures/passphrase_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('${c['passphrase']}', () {
      final p = c['passphrase'] as String;
      expect((estimateBits(p) * 10).round() / 10, c['bits']);
      expect(syncPassphraseProblem(p) != null, c['refused']);
    });
  }

  test('the word list is the one the extension has', () {
    final js = File('extension/src/vault/common_words.js').readAsStringSync();
    final list = jsonDecode(js.substring(js.indexOf('['), js.lastIndexOf(']') + 1)) as List;
    expect(list, commonWords);
  });

  test('a generated passphrase is counted at what it is worth', () {
    // Five words from the 7,776-word list and a number: about 71 bits of
    // choice, and the estimate must not be fooled into saying much more.
    for (var i = 0; i < 20; i++) {
      final p = PasswordGenerator.generatePassphrase();
      expect(estimateBits(p), inInclusiveRange(65, 95), reason: p);
      expect(syncPassphraseProblem(p), isNull, reason: p);
    }
    expect(PasswordGenerator.passphraseEntropyBits(words: 5), closeTo(71.1, 0.2));
  });

  test('a refusal says how strong it was and what would do', () {
    expect(syncPassphraseProblem('Password@12345'), contains('about 13 bits'));
    expect(describeBits(estimateBits('glacier mosaic tundra velvet')), startsWith('Strong'));
  });
}
