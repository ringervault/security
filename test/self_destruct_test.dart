import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/utils/password_generator.dart';

import 'support/render_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  late RenderHarness harness;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [
      VaultEntry(
        id: '1',
        title: 'Chase',
        username: 'jd',
        password: 'pw',
        category: 'Banking',
      ),
    ]);
  });

  tearDown(() => harness.tearDown());

  /// Drives failed attempts, absorbing the lockouts thrown along the way.
  Future<void> failTimes(int n) async {
    for (var i = 0; i < n; i++) {
      try {
        await AuthService().verifyPin('000000');
      } on AuthLockoutException {
        // Expected escalation; clear it so the next attempt lands.
        await AuthService().eraseLockoutForTest();
      }
    }
  }

  group('when disarmed', () {
    test('failures never destroy the vault', () async {
      expect(await AuthService().isSelfDestructEnabled(), isFalse);

      // Past the largest selectable threshold, so no setting could have armed
      // it. Each attempt costs a full KDF derivation, hence the raised
      // timeout, because under parallel test load this outruns the 30s default.
      await failTimes(AuthService.selfDestructChoices.last + 2);

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue,
          reason: 'a vault must not self-destruct unless armed');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('remaining attempts is null', () async {
      expect(await AuthService().attemptsBeforeDestruction(), isNull);
    });
  });

  group('when armed', () {
    setUp(() => AuthService().setSelfDestruct(enabled: true, threshold: 15));

    test('survives failures below the threshold', () async {
      await failTimes(14);

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
      expect(await AuthService().attemptsBeforeDestruction(), 1);
    });

    test('the correct PIN still works right up to the threshold', () async {
      await failTimes(14);
      await AuthService().eraseLockoutForTest();

      expect(await AuthService().verifyPin(pin), isTrue);
    });

    test('a success resets the counter', () async {
      await failTimes(10);
      await AuthService().eraseLockoutForTest();
      await AuthService().verifyPin(pin);

      expect(await AuthService().attemptsBeforeDestruction(), 15);
    });

    test('destroys the vault at the threshold', () async {
      await failTimes(14);
      await AuthService().eraseLockoutForTest();

      await expectLater(
        AuthService().verifyPin('000000'),
        throwsA(isA<VaultDestroyedException>()),
      );

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isFalse);
    });

    test('the old PIN cannot reopen a destroyed vault', () async {
      await failTimes(14);
      await AuthService().eraseLockoutForTest();
      try {
        await AuthService().verifyPin('000000');
      } on VaultDestroyedException {
        // expected
      }

      expect(await AuthService().verifyPin(pin), isFalse);
      expect(AuthService().isAuthenticated, isFalse);
    });

    test('a lower threshold is honoured', () async {
      await AuthService().setSelfDestruct(enabled: true, threshold: 15);
      expect(await AuthService().selfDestructThreshold(), 15);
    });
  });

  group('manual erase', () {
    test('destroys keys and data', () async {
      await AuthService().eraseVault();

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isFalse);
      expect(await AuthService().verifyPin(pin), isFalse);
    });

    test('leaves the app able to set up again', () async {
      await AuthService().eraseVault();
      await AuthService().setPin('999111');

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
      expect(StorageService().isReady, isTrue);
    });
  });

  group('PIN age', () {
    test('is recorded when the PIN is set', () async {
      final changed = await AuthService().pinLastChangedAt();
      expect(changed, isNotNull);
      expect(DateTime.now().difference(changed!).inMinutes, lessThan(5));
    });

    test('updates on change', () async {
      final first = await AuthService().pinLastChangedAt();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await AuthService().setPin('999111');

      expect((await AuthService().pinLastChangedAt())!.isAfter(first!), isTrue);
    });
  });

  group('verification mode', () {
    test('defaults to either', () async {
      expect(await AuthService().verificationMode(), VerificationMode.either);
    });

    test('round-trips', () async {
      await AuthService().setVerificationMode(VerificationMode.pin);
      expect(await AuthService().verificationMode(), VerificationMode.pin);
    });
  });

  group('password generator', () {
    test('honours length', () {
      expect(PasswordGenerator.generate(length: 24).length, 24);
    });

    test('produces a different password each time', () {
      final seen = {for (var i = 0; i < 50; i++) PasswordGenerator.generate()};
      expect(seen.length, greaterThan(45),
          reason: 'a predictable generator would undermine every credential');
    });

    test('guarantees a character from each enabled set', () {
      for (var i = 0; i < 40; i++) {
        final pw = PasswordGenerator.generate(length: 8);
        expect(pw, matches(RegExp(r'[a-z]')));
        expect(pw, matches(RegExp(r'[A-Z]')));
        expect(pw, matches(RegExp(r'[0-9]')));
        expect(pw, matches(RegExp(r'[!@#\$%^&*\-_=+?]')));
      }
    });

    test('omits ambiguous glyphs', () {
      for (var i = 0; i < 40; i++) {
        expect(PasswordGenerator.generate(length: 40),
            isNot(matches(RegExp(r'[lI1O0]'))));
      }
    });

    test('respects disabled sets', () {
      final pw = PasswordGenerator.generate(
          length: 30, symbols: false, digits: false);
      expect(pw, isNot(matches(RegExp(r'[0-9!@#]'))));
    });

    test('never returns empty when everything is disabled', () {
      final pw = PasswordGenerator.generate(
        length: 16,
        lowercase: false,
        uppercase: false,
        digits: false,
        symbols: false,
      );
      expect(pw.length, 16);
    });

    test('clamps out-of-range lengths', () {
      expect(PasswordGenerator.generate(length: 2).length,
          PasswordGenerator.minLength);
      expect(PasswordGenerator.generate(length: 500).length,
          PasswordGenerator.maxLength);
    });
  });
}
