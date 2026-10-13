import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/utils/unlock_secret.dart';

import 'support/render_harness.dart';

/// In-memory stand-in for the platform keystore.
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

  const pin = '482916';
  const decoyPin = '246801';
  const password = 'cedar-harbor-lantern';
  const decoyPassword = 'willow-thicket-otter';

  late _FakeSecureStorage storage;
  late Directory hiveDir;

  setUp(() async {
    storage = _FakeSecureStorage()..install();
    SharedPreferencesStub.install();

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
    // The service caches the type, and the cache outlives a single test.
    await AuthService().loadUnlockSecretType();
  });

  tearDown(() async {
    await StorageService().close();
    await Hive.deleteFromDisk();
    await Hive.close();
    await hiveDir.delete(recursive: true);
    storage.uninstall();
    AuthService().isDecoyMode = false;
  });

  VaultEntry entry(String title) => VaultEntry(
        id: 'id-$title',
        title: title,
        username: 'user',
        password: 'pw-$title',
        category: 'Banking',
      );

  group('a password-protected vault', () {
    setUp(() async {
      await AuthService()
          .setPin(password, type: UnlockSecretType.password);
    });

    test('opens with the password', () async {
      await AuthService().logout();
      expect(await AuthService().verifyPin(password), isTrue);
    });

    test('refuses a wrong password', () async {
      await AuthService().logout();
      expect(await AuthService().verifyPin('cedar-harbor-lanterx'), isFalse);
    });

    test('refuses the right password with a character missing', () async {
      await AuthService().logout();
      expect(await AuthService().verifyPin('cedar-harbor-lanter'), isFalse);
    });

    test('remembers which form to ask for, across a restart', () async {
      // A fresh read, as a cold start would do.
      expect(
        await AuthService().loadUnlockSecretType(),
        UnlockSecretType.password,
      );
    });

    test('accepts the password for in-session re-authentication', () async {
      expect(await AuthService().verifyPinForReAuth(password), isTrue);
      expect(await AuthService().verifyPinForReAuth(pin), isFalse);
    });
  });

  group('rules are enforced by the service, not only the UI', () {
    test('a short password is refused and changes nothing', () async {
      await AuthService().setPin(pin);

      await expectLater(
        AuthService().setPin('short', type: UnlockSecretType.password),
        throwsA(isA<WeakSecretException>()),
      );

      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue,
          reason: 'the old secret must still work after a refusal');
      expect(AuthService().unlockSecretType, UnlockSecretType.pin,
          reason: 'a refused change must not switch the form');
    });

    test('an obvious PIN is refused', () async {
      await expectLater(
        AuthService().setPin('123456'),
        throwsA(isA<WeakSecretException>()),
      );
      await expectLater(
        AuthService().setPin('111111'),
        throwsA(isA<WeakSecretException>()),
      );
    });

    test('a decoy secret must take the same form as the real one', () async {
      await AuthService()
          .setPin(password, type: UnlockSecretType.password);

      // A 6-digit decoy behind a password-protected vault would be guessable
      // in minutes and tell-ably different from the real one.
      await expectLater(
        AuthService().setSecondaryPin(decoyPin),
        throwsA(isA<WeakSecretException>()),
      );
    });

    test('the decoy secret cannot equal the real one', () async {
      await AuthService()
          .setPin(password, type: UnlockSecretType.password);

      await expectLater(
        AuthService().setSecondaryPin(password),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('switching form', () {
    test('keeps the vault contents', () async {
      await AuthService().setPin(pin);
      await StorageService().addEntry(entry('bank'));

      await AuthService().switchUnlockSecretType(
        type: UnlockSecretType.password,
        secret: password,
      );
      await AuthService().logout();

      expect(await AuthService().verifyPin(password), isTrue);
      expect(
        StorageService().getEntries().map((e) => e.title),
        contains('bank'),
        reason: 'the master key is re-sealed, never re-generated',
      );
    });

    test('retires the old secret', () async {
      await AuthService().setPin(pin);
      await AuthService().switchUnlockSecretType(
        type: UnlockSecretType.password,
        secret: password,
      );
      await AuthService().logout();

      expect(await AuthService().verifyPin(pin), isFalse,
          reason: 'two secrets opening one vault would make the choice a lie');
    });

    test('moves the decoy across in the same step', () async {
      await AuthService().setPin(pin);
      await AuthService().setSecondaryPin(decoyPin);

      await AuthService().switchUnlockSecretType(
        type: UnlockSecretType.password,
        secret: password,
        decoySecret: decoyPassword,
      );
      await AuthService().logout();

      expect(await AuthService().verifyPin(decoyPassword), isTrue);
      expect(AuthService().isDecoyMode, isTrue);

      await AuthService().logout();
      expect(await AuthService().verifyPin(decoyPin), isFalse,
          reason: 'a decoy left in the old form stays guessable');
    });

    test('refuses to strand a decoy in the old form', () async {
      await AuthService().setPin(pin);
      await AuthService().setSecondaryPin(decoyPin);

      await expectLater(
        AuthService().switchUnlockSecretType(
          type: UnlockSecretType.password,
          secret: password,
        ),
        throwsA(isA<StateError>()),
      );

      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue,
          reason: 'nothing should have changed');
    });

    test('refuses a decoy secret equal to the new real one', () async {
      await AuthService().setPin(pin);
      await AuthService().setSecondaryPin(decoyPin);

      await expectLater(
        AuthService().switchUnlockSecretType(
          type: UnlockSecretType.password,
          secret: password,
          decoySecret: password,
        ),
        throwsA(isA<Exception>()),
      );

      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
    });

    test('works in the other direction too', () async {
      await AuthService()
          .setPin(password, type: UnlockSecretType.password);
      await AuthService().switchUnlockSecretType(
        type: UnlockSecretType.pin,
        secret: pin,
      );
      await AuthService().logout();

      expect(await AuthService().verifyPin(pin), isTrue);
      expect(AuthService().unlockSecretType, UnlockSecretType.pin);
    });
  });

  group('replacing the decoy', () {
    test('leaves the real vault untouched', () async {
      await AuthService().setPin(pin);
      await StorageService().addEntry(entry('bank'));
      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().setSecondaryPin('864209');

      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(StorageService().getEntries().map((e) => e.title),
          contains('bank'));
    });

    test('does not leave the old decoy contents on disk', () async {
      await AuthService().setPin(pin);
      await AuthService().setSecondaryPin(decoyPin);

      await AuthService().logout();
      await AuthService().verifyPin(decoyPin);
      await StorageService().addEntry(entry('fake'));
      await AuthService().logout();

      // Re-setting mints a new decoy key, which leaves the old box encrypted
      // under a key that no longer exists. It used to be left behind silently.
      await AuthService().verifyPin(pin);
      await AuthService().setSecondaryPin('864209');

      await AuthService().logout();
      await AuthService().verifyPin('864209');
      expect(StorageService().getEntries(), isEmpty);
    });
  });

  group('after a wipe', () {
    test('the form resets so setup starts from scratch', () async {
      await AuthService()
          .setPin(password, type: UnlockSecretType.password);
      await AuthService().eraseVault();

      expect(AuthService().unlockSecretType, UnlockSecretType.pin);
      expect(await AuthService().loadUnlockSecretType(),
          UnlockSecretType.pin);
      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isFalse);
    });
  });
}
