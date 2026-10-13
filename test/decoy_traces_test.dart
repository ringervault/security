import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/repository/vault_repository.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/services/vault_session.dart';

import 'support/render_harness.dart';

/// Nothing readable without the real vault's key says whether a decoy
/// exists: not the vault file (vault_cipher_test.dart), and not secure
/// storage, checked here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  const decoyPin = '246801';
  late RenderHarness harness;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin);
    // A first unlock, as after setting up.
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
  });

  tearDown(() => harness.tearDown());

  Set<String> keyNames() => harness.secureStorage.keys.toSet();

  test('without a decoy, the decoy\'s key records are there all the same', () {
    expect(keyNames(), containsAll(['vk_wrapped_pin_2', 'vk_salt_2', 'vk_kdf_params_2']));
    expect(harness.secureStorage['vk_wrapped_pin_2']!.length,
        harness.secureStorage['vk_wrapped_pin']!.length,
        reason: 'a stand-in the same size as a real sealed key');
    expect(harness.secureStorage['vk_kdf_params_2'], harness.secureStorage['vk_kdf_params']);
  });

  test('setting up a decoy adds no key and no marker', () async {
    final before = keyNames();
    await AuthService().setSecondaryPin(decoyPin);
    expect(keyNames(), before);
    expect(harness.secureStorage.values, isNot(contains('__CONFIGURED__')));
    expect(await AuthService().isSecondaryPinSet(), isTrue, reason: 'the real vault knows');
  });

  test('turning the decoy off leaves the same keys behind', () async {
    final before = keyNames();
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().setSecondaryPin('');
    expect(keyNames(), before);
    expect(await AuthService().isSecondaryPinSet(), isFalse);
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isFalse, reason: 'gone for good');
  });

  test('any PIN against the stand-in fails like a wrong one', () async {
    await AuthService().logout();
    expect(await AuthService().verifyPin('999999'), isFalse);
    expect(await AuthService().verifyPin(pin), isTrue);
  });

  test('the decoy cannot tell it is one', () async {
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue);
    expect(AuthService().isDecoyMode, isTrue);
    expect(await AuthService().isSecondaryPinSet(), isFalse);
  });

  test('the old readable marker is moved inside the real vault', () async {
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
    // As an older build left it.
    harness.secureStorage['secondary_pin'] = '__CONFIGURED__';
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(harness.secureStorage.containsKey('secondary_pin'), isFalse);
    expect(await AuthService().isSecondaryPinSet(), isTrue);
  });

  group('every unlock costs the same', () {
    /// Key derivations one attempt runs, and whether it opened anything.
    Future<(int, bool)> attempt(String candidate) async {
      await AuthService().logout();
      VaultKeyService.derivations = 0;
      final ok = await AuthService().verifyPin(candidate);
      return (VaultKeyService.derivations, ok);
    }

    test('with no decoy: the real PIN and a wrong one', () async {
      expect(await attempt(pin), (2, true));
      expect(await attempt('999999'), (2, false));
    });

    test('with no decoy records at all (an old decoy not yet moved)', () async {
      for (final k in ['vk_wrapped_pin_2', 'vk_salt_2', 'vk_kdf_params_2']) {
        harness.secureStorage.remove(k);
      }
      expect(await attempt('999999'), (2, false));
      // The real vault's unlock puts the stand-in back, so check before it.
      for (final k in ['vk_wrapped_pin_2', 'vk_salt_2', 'vk_kdf_params_2']) {
        harness.secureStorage.remove(k);
      }
      expect(await attempt(pin), (2, true));
    });

    test('with a decoy: the real PIN, the decoy PIN and a wrong one', () async {
      await AuthService().setSecondaryPin(decoyPin);
      expect(await attempt(pin), (2, true));
      expect(await attempt(decoyPin), (2, true));
      expect(AuthService().isDecoyMode, isTrue);
      expect(await attempt('999999'), (2, false));
    });

    test('on a phone short of memory: one after the other, the same two', () async {
      VaultSession.debugLowMemory = true;
      addTearDown(() => VaultSession.debugLowMemory = null);
      await AuthService().setSecondaryPin(decoyPin);
      expect(await attempt(pin), (2, true));
      expect(await attempt(decoyPin), (2, true));
      expect(await attempt('999999'), (2, false));
    });

    test('a wrong PIN leaves the same trace with or without a decoy', () async {
      Future<Map<String, String>> afterWrong() async {
        await AuthService().logout();
        final before = Map.of(harness.secureStorage);
        expect(await AuthService().verifyPin('999999'), isFalse);
        return {
          for (final e in harness.secureStorage.entries)
            if (before[e.key] != e.value) e.key: e.key.contains('lockout') ? 'time' : e.value,
        };
      }

      // The device's security log is set up by the first failure ever,
      // with or without a decoy; that first time is not the comparison.
      await afterWrong();
      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);

      final without = await afterWrong();
      expect(await AuthService().verifyPin(pin), isTrue);
      await AuthService().setSecondaryPin(decoyPin);
      // Back to one failure so far, as before.
      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
      final withDecoy = await afterWrong();
      expect(withDecoy, without);
    });
  });

  group('nothing about a vault in the app\'s preferences', () {
    Future<Set<String>> prefKeys() async => (await SharedPreferences.getInstance()).getKeys();

    test('a new decoy is filled when it is made, and its name is kept nowhere', () async {
      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().fillNewDecoy(const DecoyIdentity(name: 'Ada Lovelace', email: 'ada@example.org'));
      expect((await prefKeys()).where((k) => k.startsWith('profile_display')), isEmpty);

      await AuthService().logout();
      expect(await AuthService().verifyPin(decoyPin), isTrue);
      final entries = StorageService().getEntries();
      expect(entries, isNotEmpty, reason: 'filled already, not on first open');
      expect(entries.map((e) => '${e.username} ${e.email}').join(' '), contains('ada'));
    });

    test('category names are kept inside each vault', () async {
      await VaultRepository().addCustomCategory('Offshore');
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        expect('${prefs.get(k)}', isNot(contains('Offshore')), reason: k);
      }
      expect((await prefKeys()).where((k) => k.endsWith('_2')), isEmpty);

      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().logout();
      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(await VaultRepository().getCustomCategories(), isEmpty);
      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(await VaultRepository().getCustomCategories(), ['Offshore']);
    });

    test('categories an older version kept in preferences are moved in', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('custom_categories', ['Old one']);
      expect(await VaultRepository().getCustomCategories(), ['Old one']);
      expect(prefs.containsKey('custom_categories'), isFalse);
      expect(await VaultRepository().getCustomCategories(), ['Old one']);
    });
  });

  group('the fingerprint opens nothing it should not', () {
    setUp(() {
      harness.secureStorage['biometric_enabled'] = 'true';
      VaultSession.debugFingerprintAllowed = false;
    });
    tearDown(() => VaultSession.debugFingerprintAllowed = null);

    test('a fresh start offers it only after the real PIN', () async {
      await AuthService().logout();
      expect(await AuthService().canOfferFingerprint(), isFalse);
      expect(await AuthService().authenticate(), isFalse, reason: 'refused, not only hidden');
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(await AuthService().canOfferFingerprint(), isTrue);
    });

    test('opening the decoy withdraws it until the real PIN again', () async {
      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().logout();
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(await AuthService().canOfferFingerprint(), isTrue);
      await AuthService().logout();
      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(await AuthService().canOfferFingerprint(), isFalse);
      await AuthService().logout();
      expect(await AuthService().unlockWithBiometric(), isFalse);
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(await AuthService().canOfferFingerprint(), isTrue);
    });
  });

  test('records under the old "_decoy" names are moved to the plain ones', () async {
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
    // As an older build left them.
    for (final base in ['vk_salt', 'vk_kdf_params', 'vk_wrapped_pin']) {
      harness.secureStorage['${base}_decoy'] = harness.secureStorage.remove('${base}_2')!;
    }
    VaultKeyService.debugForgetRenamed(); // a new run of the app
    expect(await AuthService().verifyPin(decoyPin), isTrue, reason: 'the decoy still opens');
    expect(harness.secureStorage.keys.where((k) => k.contains('decoy')), isEmpty);
  });
}
