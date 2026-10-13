import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';

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
    hiveDir = await Directory.systemTemp.createTemp('ringer_log');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => hiveDir.path,
    );

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(VaultEntryAdapter());
    }

    AuthService().isDecoyMode = false;
    await AuthService().logout();
    await ActivityLogService().init();
  });

  tearDown(() async {
    await StorageService().close();
    await Hive.deleteFromDisk();
    await Hive.close();
    await hiveDir.delete(recursive: true);
    storage.uninstall();
    AuthService().isDecoyMode = false;
  });

  List<String> actions() =>
      ActivityLogService().getLogs().map((l) => l['action'] as String).toList();

  List<String> details() => ActivityLogService()
      .getLogs()
      .map((l) => (l['details'] ?? '').toString())
      .toList();

  Future<void> setUpBothVaults() async {
    await AuthService().setPin(primaryPin);
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
  }

  group('encryption at rest', () {
    test('the old cleartext log box is destroyed on init', () async {
      expect(await Hive.boxExists('activity_log_box'), isFalse);
    });

    test('entry titles are not readable without the vault key', () async {
      await setUpBothVaults();
      await AuthService().verifyPin(primaryPin);
      await ActivityLogService().logActivity(
        action: 'Entry Added',
        details: 'Banking: Chase Personal',
      );
      await AuthService().logout();

      // The vault's log is kept in its slot of the vault file: read every
      // file straight off disk.
      final files = hiveDir.listSync().whereType<File>();
      expect(files.where((f) => f.path.endsWith('vault.rvc')), isNotEmpty);
      expect(files.where((f) => f.path.contains('vault_log_box')), isEmpty,
          reason: 'no separate log file per vault');

      for (final file in files) {
        final bytes = file.readAsBytesSync();
        expect(String.fromCharCodes(bytes), isNot(contains('Chase Personal')),
            reason: 'vault log must not be readable on disk');
      }
    });
  });

  group('decoy isolation', () {
    test('real vault events are invisible from the decoy', () async {
      await setUpBothVaults();

      await AuthService().verifyPin(primaryPin);
      await ActivityLogService().logActivity(
        action: 'Entry Added',
        details: 'Banking: Chase Personal',
      );
      await AuthService().logout();

      await AuthService().verifyPin(decoyPin);

      expect(details().join(' '), isNot(contains('Chase Personal')));
    });

    test('decoy events are invisible from the real vault', () async {
      await setUpBothVaults();

      await AuthService().verifyPin(decoyPin);
      await ActivityLogService().logActivity(
        action: 'Entry Added',
        details: 'Social: Fake Account',
      );
      await AuthService().logout();

      await AuthService().verifyPin(primaryPin);

      expect(details().join(' '), isNot(contains('Fake Account')));
    });

    test('the real vault does not record decoy access', () async {
      await setUpBothVaults();

      await AuthService().verifyPin(decoyPin);
      await AuthService().logout();
      await AuthService().verifyPin(primaryPin);

      expect(actions(), isNot(contains('Decoy Vault Access')));
    });

    test('the decoy cannot learn the real vault was ever opened', () async {
      await setUpBothVaults();

      await AuthService().verifyPin(primaryPin);
      await AuthService().logout();
      await AuthService().verifyPin(decoyPin);

      // This is the direction that matters: someone who coerced the decoy PIN
      // out of the user must find no trace of the real vault.
      expect(actions(), isNot(contains('Vault Unlocked')));
      expect(actions().where((a) => a == 'Decoy Vault Access'), hasLength(1),
          reason: 'the decoy should see exactly its own unlock');
    });
  });

  group('security log', () {
    test('failed attempts are recorded before any vault is open', () async {
      await setUpBothVaults();

      await AuthService().verifyPin('000000');

      expect(actions(), contains('Auth Failure'));
    });

    test('failures survive into a later session', () async {
      await setUpBothVaults();
      await AuthService().verifyPin('000000');

      await AuthService().verifyPin(primaryPin);

      expect(actions(), contains('Auth Failure'),
          reason: 'attack evidence must not be lost on unlock');
    });

    test('failures are visible from both vaults', () async {
      await setUpBothVaults();
      await AuthService().verifyPin('000000');

      await AuthService().verifyPin(decoyPin);
      expect(actions(), contains('Auth Failure'));
    });

    test('vault events are dropped when no vault is open', () async {
      await setUpBothVaults();

      await ActivityLogService().logActivity(
        action: 'Entry Added',
        details: 'Banking: Chase Personal',
      );

      expect(details().join(' '), isNot(contains('Chase Personal')),
          reason: 'with no key available there is nowhere safe to write it');
    });
  });
}
