@TestOn('browser')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

/// The web build of flutter_secure_storage still routes through a method
/// channel, so the same in-memory stand-in works here.
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

  test('the key envelope round-trips in a browser', () async {
    final created = await keys.createVault(pin: pin, isDecoy: false);
    final recovered = await keys.unlockWithPin(pin: pin, isDecoy: false);

    expect(recovered, equals(created));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a wrong PIN recovers nothing', () async {
    await keys.createVault(pin: pin, isDecoy: false);
    expect(await keys.unlockWithPin(pin: '000000', isDecoy: false), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('vaults stay independent on web', () async {
    await keys.createVault(pin: pin, isDecoy: false);
    await keys.createVault(pin: decoyPin, isDecoy: true);

    expect(await keys.unlockWithPin(pin: decoyPin, isDecoy: false), isNull);
    expect(await keys.unlockWithPin(pin: pin, isDecoy: true), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('web seals with pbkdf2, not the pure-Dart Argon2id path', () async {
    await keys.createVault(pin: pin, isDecoy: false);

    expect(storage.values['vk_kdf_params'], contains('pbkdf2'),
        reason: 'Argon2id in JS takes ~13s and would freeze the tab');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('unlocking stays interactive', () async {
    await keys.createVault(pin: pin, isDecoy: false);

    final sw = Stopwatch()..start();
    await keys.unlockWithPin(pin: pin, isDecoy: false);
    sw.stop();

    // ignore: avoid_print
    print('WEB_UNLOCK_MS=${sw.elapsedMilliseconds}');
    expect(sw.elapsedMilliseconds, lessThan(2000));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
