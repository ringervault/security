import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

/// In-memory stand-in for the platform keystore, so AuthService can be
/// exercised without a device.
class _FakeSecureStorage {
  final Map<String, String> values = {};

  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'write':
          values[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return values[args['key'] as String];
        case 'delete':
          values.remove(args['key'] as String);
          return null;
        case 'deleteAll':
          values.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
        case 'containsKey':
          return values.containsKey(args['key'] as String);
      }
      return null;
    });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const primaryPin = '482916';
  const decoyPin = '246801';

  late _FakeSecureStorage storage;
  late Directory hiveDir;

  setUp(() async {
    storage = _FakeSecureStorage()..install();

    // _onFailure writes to the activity log, and setPin now mints a key and
    // opens a real vault, so Hive has to be live.
    hiveDir = await Directory.systemTemp.createTemp('ringer_vault_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => hiveDir.path,
    );
    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(VaultEntryAdapter());
    }
    await ActivityLogService().init();

    AuthService().isDecoyMode = false;
    await AuthService().logout();
    await AuthService().setPin(primaryPin);
    await AuthService().setSecondaryPin(decoyPin);
  });

  tearDown(() async {
    await StorageService().close();
    await Hive.deleteFromDisk();
    await Hive.close();
    await hiveDir.delete(recursive: true);
    storage.uninstall();
    AuthService().isDecoyMode = false;
  });

  group('verifyPinForReAuth: real vault open', () {
    test('accepts the primary PIN', () async {
      expect(await AuthService().verifyPinForReAuth(primaryPin), isTrue);
    });

    test('rejects the decoy PIN', () async {
      expect(await AuthService().verifyPinForReAuth(decoyPin), isFalse);
    });

    test('rejects an unrelated PIN', () async {
      expect(await AuthService().verifyPinForReAuth('999999'), isFalse);
    });

    test('does not switch vault mode when given the decoy PIN', () async {
      await AuthService().verifyPinForReAuth(decoyPin);
      expect(AuthService().isDecoyMode, isFalse,
          reason: 'a re-auth prompt must never swap the open vault');
    });
  });

  group('verifyPinForReAuth: decoy vault open', () {
    setUp(() => AuthService().isDecoyMode = true);

    test('accepts the decoy PIN', () async {
      expect(await AuthService().verifyPinForReAuth(decoyPin), isTrue);
    });

    test('rejects the primary PIN, preserving deniability', () async {
      expect(await AuthService().verifyPinForReAuth(primaryPin), isFalse,
          reason: 'demanding the real PIN would prove a real vault exists');
    });

    test('does not switch vault mode', () async {
      await AuthService().verifyPinForReAuth(decoyPin);
      expect(AuthService().isDecoyMode, isTrue);
    });
  });

  group('lockout', () {
    test('escalates to a lockout after repeated failures', () async {
      // Policy: 5 failures -> 30s. The 5th throws.
      for (var i = 0; i < 4; i++) {
        expect(await AuthService().verifyPinForReAuth('000000'), isFalse);
      }
      await expectLater(
        AuthService().verifyPinForReAuth('000000'),
        throwsA(isA<AuthLockoutException>()),
      );
    });

    test('a correct PIN is still refused while locked out', () async {
      for (var i = 0; i < 4; i++) {
        await AuthService().verifyPinForReAuth('000000');
      }
      await expectLater(AuthService().verifyPinForReAuth('000000'),
          throwsA(isA<AuthLockoutException>()));

      await expectLater(
        AuthService().verifyPinForReAuth(primaryPin),
        throwsA(isA<AuthLockoutException>()),
        reason: 'lockout must gate the check itself, not just wrong guesses',
      );
    });

    test('a successful re-auth clears the failure counter', () async {
      for (var i = 0; i < 3; i++) {
        await AuthService().verifyPinForReAuth('000000');
      }
      expect(await AuthService().verifyPinForReAuth(primaryPin), isTrue);

      // Counter reset, so four more failures must not trip the 5-strike rule.
      for (var i = 0; i < 4; i++) {
        expect(await AuthService().verifyPinForReAuth('000000'), isFalse);
      }
    });
  });

  group('biometric re-auth', () {
    // With biometrics disabled both entry points short-circuit before touching
    // the platform channel, which is enough to pin down the session-state
    // contract without mocking the OS prompt.

    test('re-auth declines when biometrics are disabled', () async {
      await AuthService().setBiometricEnabled(false);
      expect(await AuthService().authenticateForReAuth('reveal'), isFalse);
    });

    test('re-auth leaves decoy mode untouched', () async {
      await AuthService().setBiometricEnabled(false);
      AuthService().isDecoyMode = true;

      await AuthService().authenticateForReAuth('reveal');

      expect(AuthService().isDecoyMode, isTrue,
          reason: 'biometric re-auth must never swap in the real vault');
    });

    test('re-auth does not start a session', () async {
      await AuthService().setBiometricEnabled(false);
      // Creating the vault in setUp legitimately authenticates; a re-auth must
      // not be able to authenticate on its own from a locked state.
      await AuthService().logout();

      await AuthService().authenticateForReAuth('reveal');

      expect(AuthService().isAuthenticated, isFalse);
    });

    test('a declined prompt does not count toward PIN lockout', () async {
      await AuthService().setBiometricEnabled(false);

      // Ten declined biometric prompts, which under the old code path would
      // have tripped the 5- and 10-failure thresholds.
      for (var i = 0; i < 10; i++) {
        await AuthService().authenticateForReAuth('reveal');
      }

      expect(await AuthService().verifyPinForReAuth(primaryPin), isTrue,
          reason: 'cancelling a fingerprint prompt is not an attack');
    });
  });

  group('biometric unlock', () {
    test('never opens the vault without a successful prompt', () async {
      // Enrol a biometric envelope, then attempt unlock in an environment
      // where no prompt can succeed (no sensor under test).
      final masterKey = StorageService().activeMasterKey!;
      await VaultKeyService().enableBiometricUnlock(
        masterKey: masterKey,
        isDecoy: false,
      );
      await AuthService().setBiometricEnabled(true);
      await AuthService().logout();

      final opened = await AuthService().unlockWithBiometric();

      expect(opened, isFalse,
          reason: 'reading the envelope must not be sufficient on its own: '
              'flutter_secure_storage does not raise a prompt for us');
      expect(AuthService().isAuthenticated, isFalse);
      expect(StorageService().isReady, isFalse);
    });
  });

  group('PIN uniqueness', () {
    test('a decoy PIN equal to the primary PIN is refused', () async {
      await expectLater(
        AuthService().setSecondaryPin(primaryPin),
        throwsA(isA<Exception>()),
      );
    });

    test('a primary PIN equal to the decoy PIN is refused', () async {
      await expectLater(
        AuthService().setPin(decoyPin),
        throwsA(isA<Exception>()),
      );
    });

    test('the __DISABLED__ sentinel never matches a real PIN', () async {
      await AuthService().setSecondaryPin('__DISABLED__');
      expect(await AuthService().isSecondaryPin('__DISABLED__'), isFalse);
      expect(await AuthService().isSecondaryPinSet(), isFalse);
    });
  });
}
