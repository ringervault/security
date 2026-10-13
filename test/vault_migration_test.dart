import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

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

  const primaryPin = '482916';
  const decoyPin = '246801';

  late _FakeSecureStorage storage;
  late Directory hiveDir;

  setUp(() async {
    storage = _FakeSecureStorage()..install();
    hiveDir = await Directory.systemTemp.createTemp('ringer_migration');

    // StorageService.init() goes through Hive.initFlutter(), which asks
    // path_provider where to put the boxes.
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

  /// Recreates a vault in the pre-upgrade format: a plaintext master key and
  /// plaintext PINs in secure storage, both vaults under the same key.
  Future<Uint8List> seedLegacyVault({
    required List<VaultEntry> realEntries,
    List<VaultEntry> decoyEntries = const [],
    bool withDecoy = false,
  }) async {
    final legacyKey = Uint8List.fromList(Hive.generateSecureKey());

    storage.values[VaultKeyService.legacyMasterKeyKey] =
        base64Url.encode(legacyKey);
    storage.values['user_pin'] = primaryPin;
    if (withDecoy) storage.values['secondary_pin'] = decoyPin;

    final realBox = await Hive.openBox<VaultEntry>(
      StorageService.legacyRealVaultBoxName,
      encryptionCipher: HiveAesCipher(legacyKey),
    );
    await realBox.putAll({for (final e in realEntries) e.id: e});
    await realBox.close();

    if (withDecoy) {
      final decoyBox = await Hive.openBox<VaultEntry>(
        StorageService.legacyDecoyVaultBoxName,
        encryptionCipher: HiveAesCipher(legacyKey),
      );
      await decoyBox.putAll({for (final e in decoyEntries) e.id: e});
      await decoyBox.close();
    }

    return legacyKey;
  }

  group('migration of an existing vault', () {
    test('the old PIN still unlocks after upgrading', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);

      expect(await AuthService().verifyPin(primaryPin), isTrue);
    });

    test('entries survive migration intact', () async {
      await seedLegacyVault(realEntries: [entry('Chase'), entry('Gmail')]);

      await AuthService().verifyPin(primaryPin);
      final titles = StorageService().getEntries().map((e) => e.title).toList();

      expect(titles, containsAll(['Chase', 'Gmail']));
    });

    test('the plaintext PIN is destroyed', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);
      await AuthService().verifyPin(primaryPin);

      expect(storage.values.containsKey('user_pin'), isFalse);
    });

    test('the plaintext master key is destroyed', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);
      await AuthService().verifyPin(primaryPin);

      expect(
        storage.values.containsKey(VaultKeyService.legacyMasterKeyKey),
        isFalse,
        reason: 'the plaintext key is what made the PIN cosmetic',
      );
    });

    test('a PIN envelope replaces it', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);
      await AuthService().verifyPin(primaryPin);

      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
    });

    test('the wrong PIN still fails after migration', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);
      await AuthService().verifyPin(primaryPin);
      await AuthService().logout();

      expect(await AuthService().verifyPin('000000'), isFalse);
    });

    test('unlocking twice works, so migration is not one-shot', () async {
      await seedLegacyVault(realEntries: [entry('Chase')]);

      expect(await AuthService().verifyPin(primaryPin), isTrue);
      await AuthService().logout();
      expect(await AuthService().verifyPin(primaryPin), isTrue);
      expect(StorageService().getEntries(), hasLength(1));
    });
  });

  group('migration with a decoy vault', () {
    test('the decoy PIN opens the decoy vault', () async {
      await seedLegacyVault(
        realEntries: [entry('Chase')],
        decoyEntries: [entry('Fake')],
        withDecoy: true,
      );

      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(AuthService().isDecoyMode, isTrue);
      expect(StorageService().getEntries().single.title, 'Fake');
    });

    test('the decoy is re-keyed onto a key of its own', () async {
      final legacyKey = await seedLegacyVault(
        realEntries: [entry('Chase')],
        decoyEntries: [entry('Fake')],
        withDecoy: true,
      );

      await AuthService().verifyPin(decoyPin);

      final decoyKey = StorageService().activeMasterKey;
      expect(decoyKey, isNotNull);
      expect(decoyKey, isNot(equals(legacyKey)),
          reason: 'sharing the real vault key made the decoy cosmetic');
    });

    test('the real vault is still reachable after the decoy migrates',
        () async {
      await seedLegacyVault(
        realEntries: [entry('Chase')],
        decoyEntries: [entry('Fake')],
        withDecoy: true,
      );

      await AuthService().verifyPin(decoyPin);
      await AuthService().logout();

      expect(await AuthService().verifyPin(primaryPin), isTrue);
      expect(AuthService().isDecoyMode, isFalse);
      expect(StorageService().getEntries().single.title, 'Chase');
    });

    test('both vaults survive migrating in either order', () async {
      await seedLegacyVault(
        realEntries: [entry('Chase')],
        decoyEntries: [entry('Fake')],
        withDecoy: true,
      );

      await AuthService().verifyPin(primaryPin);
      await AuthService().logout();
      await AuthService().verifyPin(decoyPin);
      await AuthService().logout();

      expect(await AuthService().verifyPin(primaryPin), isTrue);
      expect(StorageService().getEntries().single.title, 'Chase');
      await AuthService().logout();

      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(StorageService().getEntries().single.title, 'Fake');
    });
  });

  group('a freshly created vault', () {
    test('setPin mints a key and opens the vault', () async {
      await AuthService().setPin(primaryPin);

      expect(StorageService().isReady, isTrue);
      expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
    });

    test('never stores the PIN', () async {
      await AuthService().setPin(primaryPin);

      for (final entry in storage.values.entries) {
        expect(entry.value, isNot(contains(primaryPin)),
            reason: 'PIN leaked into ${entry.key}');
      }
    });

    test('changing the PIN preserves entries', () async {
      await AuthService().setPin(primaryPin);
      await StorageService().addEntry(entry('Chase'));

      await AuthService().setPin('999111');
      await AuthService().logout();

      expect(await AuthService().verifyPin('999111'), isTrue);
      expect(StorageService().getEntries().single.title, 'Chase');
    });

    test('the retired PIN stops working', () async {
      await AuthService().setPin(primaryPin);
      await AuthService().setPin('999111');
      await AuthService().logout();

      expect(await AuthService().verifyPin(primaryPin), isFalse);
    });

    test('the decoy gets an independent key', () async {
      await AuthService().setPin(primaryPin);
      final realKey = StorageService().activeMasterKey;

      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().logout();

      await AuthService().verifyPin(decoyPin);
      expect(StorageService().activeMasterKey, isNot(equals(realKey)));
    });
  });
}
