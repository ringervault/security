import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/repository/vault_repository.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/render_harness.dart';

/// Everything on the phone that can be seen without a key, compared with a
/// decoy and without one. The same things are done in both, except that one
/// has a decoy and uses it; nothing readable may differ. A new file, key or
/// preference with "_decoy" in its name, or a file that grows with a second
/// vault, fails here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  const decoyPin = '246801';

  VaultEntry entry(String id) =>
      VaultEntry(id: id, title: 'Title $id', username: 'user', password: 'pw-$id', category: 'Banking');

  /// What can be read off the phone afterwards: every file with its size,
  /// and the names (not the values, which are encrypted or random) of
  /// every secure-storage key and preference.
  Future<Map<String, Object>> use({required bool decoy}) async {
    final harness = RenderHarness();
    await harness.setUp(pin: pin);
    try {
      final storage = StorageService();
      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
      for (final id in ['a', 'b', 'c']) {
        await storage.addEntry(entry(id));
      }
      await VaultRepository().addCustomCategory('Offshore');
      await VaultRepository().rotateDashboardCategory('Work');

      if (decoy) {
        await AuthService().setSecondaryPin(decoyPin);
        await AuthService().fillNewDecoy(const DecoyIdentity(name: 'Ada', email: 'ada@example.org'));
      }

      await AuthService().logout();
      expect(await AuthService().verifyPin('999999'), isFalse);

      // The one difference: which vault this unlock opens.
      expect(await AuthService().verifyPin(decoy ? decoyPin : pin), isTrue);
      await storage.addEntry(entry('d'));
      await storage.addEntry(entry('e'));
      await VaultRepository().addCustomCategory('Travel');
      await AuthService().logout();

      expect(await AuthService().verifyPin(pin), isTrue);
      await storage.addEntry(entry('f'));
      await AuthService().logout();

      // The stand-ins really were used (on a phone too): an empty list on
      // both sides would compare equal and prove nothing.
      expect(harness.secureStorage.keys, contains('vk_wrapped_pin'));
      expect(File('${harness.hiveDirPath}/vault.rvc').existsSync(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      return {
        'files': {
          for (final f in Directory(harness.hiveDirPath).listSync(recursive: true).whereType<File>())
            f.path.substring(harness.hiveDirPath.length): f.lengthSync(),
        },
        'secure storage': harness.secureStorage.keys.toList()..sort(),
        'preferences': prefs.getKeys().toList()..sort(),
      };
    } finally {
      await harness.tearDown();
    }
  }

  test('a decoy, used, leaves nothing readable that differs', () async {
    final without = await use(decoy: false);
    final withDecoy = await use(decoy: true);

    for (final what in without.keys) {
      expect(withDecoy[what], without[what], reason: what);
    }
    final everyName = [
      ...(withDecoy['files'] as Map).keys,
      ...withDecoy['secure storage'] as List,
      ...withDecoy['preferences'] as List,
    ];
    expect(everyName.where((n) => '$n'.toLowerCase().contains('decoy')), isEmpty);
  });
}
