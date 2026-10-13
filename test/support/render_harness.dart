import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/services/vault_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Harness for tests against a real (temporary) vault.
///
/// Widget tests normally draw text with a placeholder font where every glyph
/// is an identical box, which makes a captured image useless for judging
/// layout. This loads the actual Roboto and Material Icons faces out of the
/// Flutter SDK so goldens are legible.
class RenderHarness {
  final Map<String, String> secureStorage = {};
  late Directory _hiveDir;

  /// Where this test's vault files live, for tests that check what is on disk.
  String get hiveDirPath => _hiveDir.path;

  /// One of those files.
  File file(String name) => File('${_hiveDir.path}/$name');

  /// Between [setUp] and [tearDown].
  bool isUp = false;

  static const _secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  static const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  Future<void> setUp({
    String pin = '482916',
    List<VaultEntry> entries = const [],
  }) async {
    _installSecureStorage();

    _hiveDir = await Directory.systemTemp.createTemp('ringer_render');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (_) async => _hiveDir.path);

    SharedPreferencesStub.install();

    // Directly, not only through the platform channels below: on a phone
    // (integration_test/) Android's plugins skip those, and the test would
    // be reading and writing the app's real files and preferences.
    StorageService.debugDirectory = _hiveDir.path;
    VaultLock.debugDirectory = _hiveDir.path;
    SharedPreferences.setMockInitialValues({});
    Hive.init(_hiveDir.path);
    VaultKeyService.debugForgetRenamed();
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(VaultEntryAdapter());
    }

    AuthService().isDecoyMode = false;
    await AuthService().logout();
    await AuthService().init();
    await AuthService().setPin(pin);

    for (final e in entries) {
      await StorageService().addEntry(e);
    }
    isUp = true;
  }

  Future<void> tearDown() async {
    isUp = false;
    await StorageService().close();
    await Hive.deleteFromDisk();
    await Hive.close();
    if (_hiveDir.existsSync()) await _hiveDir.delete(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_secureChannel, null)
      ..setMockMethodCallHandler(_pathChannel, null);
  }

  void _installSecureStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'write':
          secureStorage[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secureStorage[args['key'] as String];
        case 'delete':
          secureStorage.remove(args['key'] as String);
          return null;
        case 'containsKey':
          return secureStorage.containsKey(args['key'] as String);
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
  }
}

/// shared_preferences has no platform implementation under `flutter test`.
class SharedPreferencesStub {
  static final Map<String, Object> _values = {};

  static void install() {
    _values.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async {
        switch (call.method) {
          case 'getAll':
            return Map<String, Object>.from(_values);
          case 'setBool':
          case 'setInt':
          case 'setString':
          case 'setStringList':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            _values[args['key'] as String] = args['value'] as Object;
            return true;
          case 'remove':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            _values.remove(args['key'] as String);
            return true;
          case 'clear':
            _values.clear();
            return true;
        }
        return null;
      },
    );
  }
}
