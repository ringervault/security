import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

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
        case 'containsKey':
          return values.containsKey(args['key'] as String);
        case 'deleteAll':
          values.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
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

  late _FakeSecureStorage storage;
  late VaultKeyService keys;

  setUp(() {
    storage = _FakeSecureStorage()..install();
    keys = VaultKeyService();
  });

  tearDown(() => storage.uninstall());

  group('PIN envelope', () {
    test('the correct PIN recovers the same master key', () async {
      final created = await keys.createVault(pin: pin, isDecoy: false);
      final recovered = await keys.unlockWithPin(pin: pin, isDecoy: false);

      expect(recovered, isNotNull);
      expect(recovered, equals(created));
    });

    test('a wrong PIN recovers nothing', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      expect(await keys.unlockWithPin(pin: '000000', isDecoy: false), isNull);
    });

    test('the master key is never written in the clear', () async {
      final masterKey = await keys.createVault(pin: pin, isDecoy: false);
      final plain = base64Of(masterKey);

      for (final entry in storage.values.entries) {
        expect(entry.value, isNot(contains(plain)),
            reason: 'master key leaked into ${entry.key}');
      }
    });

    test('the PIN is never written in any form', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      for (final entry in storage.values.entries) {
        expect(entry.value, isNot(contains(pin)),
            reason: 'PIN leaked into ${entry.key}');
      }
    });

    test('each vault gets a distinct salt and envelope', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      await keys.createVault(pin: pin, isDecoy: true);

      expect(storage.values['vk_salt'],
          isNot(equals(storage.values['vk_salt_decoy'])));
      expect(storage.values['vk_wrapped_pin'],
          isNot(equals(storage.values['vk_wrapped_pin_decoy'])));
    });

    test('a tampered envelope fails the tag check', () async {
      await keys.createVault(pin: pin, isDecoy: false);

      final envelope = storage.values['vk_wrapped_pin']!;
      final bytes = base64Decode(envelope);
      bytes[bytes.length - 1] ^= 0x01;
      storage.values['vk_wrapped_pin'] = base64Encode(bytes);

      expect(await keys.unlockWithPin(pin: pin, isDecoy: false), isNull);
    });
  });

  group('decoy isolation', () {
    test('the two vaults hold different master keys', () async {
      final real = await keys.createVault(pin: pin, isDecoy: false);
      final decoy = await keys.createVault(pin: decoyPin, isDecoy: true);

      expect(real, isNot(equals(decoy)),
          reason: 'a shared key would make the decoy cosmetic');
    });

    test('the decoy PIN cannot open the real vault', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      await keys.createVault(pin: decoyPin, isDecoy: true);

      expect(await keys.unlockWithPin(pin: decoyPin, isDecoy: false), isNull);
    });

    test('the real PIN cannot open the decoy vault', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      await keys.createVault(pin: decoyPin, isDecoy: true);

      expect(await keys.unlockWithPin(pin: pin, isDecoy: true), isNull);
    });

    test('destroying the real vault leaves the decoy intact', () async {
      await keys.createVault(pin: pin, isDecoy: false);
      final decoy = await keys.createVault(pin: decoyPin, isDecoy: true);

      await keys.destroyVaultKeys(isDecoy: false);

      expect(await keys.unlockWithPin(pin: pin, isDecoy: false), isNull);
      expect(await keys.unlockWithPin(pin: decoyPin, isDecoy: true),
          equals(decoy));
    });
  });

  group('changing the PIN', () {
    test('preserves the master key, so vault data survives', () async {
      final original = await keys.createVault(pin: pin, isDecoy: false);

      await keys.changePin(
          masterKey: original, newPin: '999111', isDecoy: false);

      expect(await keys.unlockWithPin(pin: '999111', isDecoy: false),
          equals(original));
    });

    test('retires the old PIN', () async {
      final original = await keys.createVault(pin: pin, isDecoy: false);
      await keys.changePin(
          masterKey: original, newPin: '999111', isDecoy: false);

      expect(await keys.unlockWithPin(pin: pin, isDecoy: false), isNull);
    });

    test('re-salts, so the same PIN yields a different envelope', () async {
      final original = await keys.createVault(pin: pin, isDecoy: false);
      final firstEnvelope = storage.values['vk_wrapped_pin'];

      await keys.changePin(masterKey: original, newPin: pin, isDecoy: false);

      expect(storage.values['vk_wrapped_pin'], isNot(equals(firstEnvelope)));
    });
  });

  group('migration from the legacy format', () {
    test('adopts an existing key without changing it', () async {
      // Stand-in for a vault already encrypted under a plaintext-stored key.
      final legacyKey = await keys.createVault(pin: 'throwaway', isDecoy: true);

      await keys.adoptExistingKey(
          masterKey: legacyKey, pin: pin, isDecoy: false);

      expect(await keys.unlockWithPin(pin: pin, isDecoy: false),
          equals(legacyKey),
          reason: 'the vault must not need re-encrypting');
    });
  });

  group('envelope presence', () {
    test('reports absent before creation and present after', () async {
      expect(await keys.hasPinEnvelope(isDecoy: false), isFalse);
      await keys.createVault(pin: pin, isDecoy: false);
      expect(await keys.hasPinEnvelope(isDecoy: false), isTrue);
    });
  });
}

String base64Of(List<int> bytes) => base64Encode(bytes);
