import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/utils/unlock_secret.dart';

/// The rules that decide what may become the vault key.
///
/// Worth testing directly: this value is the key, so anything accepted here
/// is a weakness that survives until the user happens to change it, and
/// anything wrongly rejected is a user who cannot set the secret they want.
void main() {
  group('PIN rules', () {
    const type = UnlockSecretType.pin;

    test('accepts six unremarkable digits', () {
      expect(validateUnlockSecret('482916', type), isNull);
      expect(validateUnlockSecret('999111', type), isNull);
    });

    test('requires exactly six digits', () {
      expect(validateUnlockSecret('12345', type), isNotNull);
      expect(validateUnlockSecret('1234567', type), isNotNull);
      expect(validateUnlockSecret('', type), isNotNull);
    });

    test('rejects letters', () {
      expect(validateUnlockSecret('12a456', type), isNotNull);
    });

    test('rejects a single repeated digit', () {
      expect(validateUnlockSecret('111111', type), isNotNull);
      expect(validateUnlockSecret('000000', type), isNotNull);
    });

    test('rejects straight runs in both directions', () {
      expect(validateUnlockSecret('123456', type), isNotNull);
      expect(validateUnlockSecret('654321', type), isNotNull);
    });
  });

  group('password rules', () {
    const type = UnlockSecretType.password;

    test('accepts twelve varied characters', () {
      expect(validateUnlockSecret('correct-horse-battery', type), isNull);
      expect(validateUnlockSecret('Tr0ub4dor&3x', type), isNull);
    });

    test('rejects anything under the minimum', () {
      expect(validateUnlockSecret('short', type), isNotNull);
      expect(
        validateUnlockSecret('a' * (kMinPasswordLength - 1), type),
        isNotNull,
      );
    });

    test('rejects a long but repetitive string', () {
      // Long enough to pass a length check, and no harder to guess than a
      // two-character secret.
      expect(validateUnlockSecret('abababababababab', type), isNotNull);
      expect(validateUnlockSecret('aaaaaaaaaaaaaaaa', type), isNotNull);
    });

    test('rejects surrounding whitespace rather than trimming it', () {
      // Trimming would seal a different value than the one shown, and the
      // user could never reproduce it.
      expect(validateUnlockSecret(' correct-horse-battery', type), isNotNull);
      expect(validateUnlockSecret('correct-horse-battery ', type), isNotNull);
    });

    test('keeps spaces inside a passphrase', () {
      expect(validateUnlockSecret('cedar harbor lantern', type), isNull);
    });

    test('has an upper bound', () {
      expect(
        validateUnlockSecret('a1B2' * 40, type),
        isNotNull,
      );
    });
  });

  group('strength meter', () {
    test('anything below the minimum reads as too short', () {
      expect(estimateSecretStrength('abc'), SecretStrength.tooShort);
    });

    test('rates length and variety upward', () {
      expect(estimateSecretStrength('lanternharbor'), SecretStrength.fair);
      // Many kinds of character, all of them predictable.
      expect(estimateSecretStrength('Password@12345'), SecretStrength.weak);
      expect(
        estimateSecretStrength('Lantern-Harbor1'),
        SecretStrength.fair,
      );
      expect(
        estimateSecretStrength('Lantern-Harbor-Cedar-99'),
        SecretStrength.veryStrong,
      );
    });

    test('never reports a number of bits', () {
      // Bits from length and character classes would rate "Password1234" at
      // about 71, which is false: it falls to any wordlist in seconds. The
      // meter reports only what it can defend.
      for (final strength in SecretStrength.values) {
        expect(strength.label, isNot(contains('bit')));
      }
    });
  });

  group('labels', () {
    test('name the secret the user actually has', () {
      expect(UnlockSecretType.pin.noun, 'PIN');
      expect(UnlockSecretType.password.noun, 'password');
      expect(UnlockSecretType.password.nounCapitalized, 'Password');
    });

    test('round-trip through storage', () {
      for (final type in UnlockSecretType.values) {
        expect(
          UnlockSecretTypeInfo.fromStorage(type.storageValue),
          type,
        );
      }
    });

    test('an unset or unknown stored value means PIN', () {
      expect(UnlockSecretTypeInfo.fromStorage(null), UnlockSecretType.pin);
      expect(UnlockSecretTypeInfo.fromStorage('nonsense'),
          UnlockSecretType.pin);
    });
  });
}
