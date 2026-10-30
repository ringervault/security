import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/utils/password_generator.dart';

void main() {
  group('special characters a site allows', () {
    test('only the allowed ones are used, and one is always there', () {
      for (var i = 0; i < 200; i++) {
        final password = PasswordGenerator.generate(allowedSymbols: r'_.');
        final special = password.replaceAll(RegExp(r'[A-Za-z0-9]'), '');
        expect(special, isNotEmpty);
        expect(RegExp(r'^[_.]+$').hasMatch(special), isTrue, reason: password);
      }
    });

    test("a site's own list can be pasted as it is", () {
      expect(PasswordGenerator.cleanSymbols('! @ # \$'), '!@#\$');
      expect(PasswordGenerator.cleanSymbols('!!@@'), '!@');
      expect(PasswordGenerator.cleanSymbols('é€ ¡'), '');
    });

    test('none usable means no special characters, not the usual set', () {
      for (var i = 0; i < 50; i++) {
        final password = PasswordGenerator.generate(allowedSymbols: 'abc 123');
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(password), isTrue, reason: password);
      }
    });

    test('special characters ruled out are never brought back', () {
      for (var i = 0; i < 50; i++) {
        final password = PasswordGenerator.generate(
          lowercase: false,
          uppercase: false,
          digits: false,
          allowedSymbols: '',
        );
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(password), isTrue, reason: password);
      }
    });

    test('the usual set is used when nothing is narrowed', () {
      final password = PasswordGenerator.generate(length: 64);
      final special = password.replaceAll(RegExp(r'[A-Za-z0-9]'), '');
      expect(special.split('').every(PasswordGenerator.defaultSymbols.contains), isTrue);
    });

    test('strength counts only the characters allowed', () {
      final usual = PasswordGenerator.entropyBits(length: 20);
      final two = PasswordGenerator.entropyBits(length: 20, allowedSymbols: '_.');
      expect(two, lessThan(usual));
      expect(
        PasswordGenerator.entropyBits(length: 20, allowedSymbols: ''),
        PasswordGenerator.entropyBits(length: 20, symbols: false),
      );
    });
  });
}
