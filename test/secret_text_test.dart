import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/utils/secret_text.dart';

import 'support/render_harness.dart';

/// A passphrase typed with letters composed one way or the other makes the
/// same key (lib/utils/secret_text.dart). Dart has no normaliser, so the
/// test supplies one for the letters it uses, as Android's would.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const composed = 'café déjà vu crème';
  const decomposed = 'café déjà vu crème';
  setUp(() => SecretText.debugNfc = (s) => s
      .replaceAll('é', 'é')
      .replaceAll('à', 'à')
      .replaceAll('è', 'è'));
  tearDown(() => SecretText.debugNfc = null);

  test('plain ASCII is left exactly as it is', () async {
    expect(await SecretText.forms('482916'), ['482916']);
    expect(await SecretText.forms('Lantern-Harbor-Cedar-99'), ['Lantern-Harbor-Cedar-99']);
  });

  test('a decomposed passphrase is tried composed first, then as typed', () async {
    expect(await SecretText.forms(decomposed), [composed, decomposed]);
  });

  test('sync written from one form opens with the other', () async {
    final written = await SyncCipher(decomposed).encrypt([1, 2, 3]);
    expect(await SyncCipher(composed).decrypt(written), [1, 2, 3]);
    expect(await SyncCipher(decomposed).decrypt(written), [1, 2, 3]);
  });

  test('a wrong passphrase still fails', () async {
    final written = await SyncCipher(composed).encrypt([1, 2, 3]);
    await expectLater(SyncCipher('cafe deja vu creme').decrypt(written), throwsA(isA<SyncCipherError>()));
  });

  group('the vault password', () {
    late RenderHarness harness;
    setUp(() async {
      harness = RenderHarness();
      await harness.setUp(pin: '482916');
    });
    tearDown(() => harness.tearDown());

    test('set in one form, opens typed in the other', () async {
      final master = Uint8List.fromList(List.generate(32, (i) => i));
      await VaultKeyService().changePin(masterKey: master, newPin: decomposed, isDecoy: false);
      expect(await VaultKeyService().unlockWithPin(pin: composed, isDecoy: false), master);
      expect(await VaultKeyService().unlockWithPin(pin: decomposed, isDecoy: false), master);
      expect(await VaultKeyService().unlockWithPin(pin: 'cafe deja vu creme', isDecoy: false), isNull);
    });
  });
}
