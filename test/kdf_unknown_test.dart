import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

import 'support/render_harness.dart';

/// A key function this version does not know is refused as newer, never
/// guessed at as Argon2id: that would look like a wrong PIN and count
/// towards the lockout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  late RenderHarness harness;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin);
    await AuthService().logout();
  });
  tearDown(() => harness.tearDown());

  test('an unknown key function is "newer", not a wrong PIN', () async {
    final params = jsonDecode(harness.secureStorage['vk_kdf_params']!) as Map<String, dynamic>;
    harness.secureStorage['vk_kdf_params'] = jsonEncode({...params, 'alg': 'argon3'});

    await expectLater(AuthService().verifyPin(pin), throwsA(isA<NewerVaultException>()));
    expect(await AuthService().failedAttempts(), 0, reason: 'not counted as a wrong attempt');
  });

  test('no key function named still means Argon2id, as older vaults were sealed', () async {
    final params = jsonDecode(harness.secureStorage['vk_kdf_params']!) as Map<String, dynamic>;
    expect(params['alg'], 'argon2id');
    harness.secureStorage['vk_kdf_params'] = jsonEncode({...params}..remove('alg'));
    expect(await AuthService().verifyPin(pin), isTrue);
  });
}
