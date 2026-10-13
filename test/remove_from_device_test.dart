import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

import 'support/render_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  late RenderHarness harness;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [
      VaultEntry(id: '1', title: 'Chase', username: 'jd', password: 'pw', category: 'Banking'),
    ]);
  });

  tearDown(() => harness.tearDown());

  test('removing from this phone leaves it as if freshly installed', () async {
    expect(await AuthService().verifyPin(pin), isTrue);

    var lockCallbacks = 0;
    void onLock() => lockCallbacks++;
    AuthService.onLock.add(onLock);
    addTearDown(() => AuthService.onLock.remove(onLock));

    await AuthService().removeFromThisDevice();

    // Session-held secrets (the sync key, for one) were told to go.
    expect(lockCallbacks, 1);
    // No keys: whatever might be left on disk can no longer be opened.
    expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isFalse);
    expect(await VaultKeyService().hasPinEnvelope(isDecoy: true), isFalse);
    // The old PIN opens nothing, and the session is over.
    expect(await AuthService().verifyPin(pin), isFalse);
    expect(AuthService().isAuthenticated, isFalse);
  });

  test('the phone can be set up again afterwards, as new', () async {
    await AuthService().removeFromThisDevice();
    await AuthService().setPin('999111');

    expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
    expect(StorageService().getEntries(), isEmpty);
  });
}
