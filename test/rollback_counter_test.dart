import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_cipher.dart';

import 'support/render_harness.dart';

/// The write count kept in secure storage is what catches an older copy of
/// vault.rvc being put back. Removing that record must not switch the check
/// off: a vault written more than once without one is refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  late RenderHarness harness;
  final storage = StorageService();

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [
      VaultEntry(id: '1', title: 'Bank', username: 'ada', password: 'pw', category: 'Banking'),
    ]);
  });
  tearDown(() => harness.tearDown());

  test('an older copy put back, with the count record removed, is refused', () async {
    final older = await harness.file('vault.rvc').readAsBytes();
    await storage.addEntry(VaultEntry(id: '2', title: 'Mail', username: 'ada', password: 'pw2', category: 'Email'));
    await storage.addEntry(VaultEntry(id: '3', title: 'Shop', username: 'ada', password: 'pw3', category: 'Utility'));
    await AuthService().logout();

    await harness.file('vault.rvc').writeAsBytes(older);
    await harness.file('vault.rvc.prev').delete().catchError((_) => harness.file('x'));
    harness.secureStorage.remove('vc_count_a');

    await expectLater(AuthService().verifyPin(pin), throwsA(isA<VaultTamperedError>()));
  });

  test('the current file with its count record removed is refused too', () async {
    await storage.addEntry(VaultEntry(id: '2', title: 'Mail', username: 'ada', password: 'pw2', category: 'Email'));
    await AuthService().logout();
    harness.secureStorage.remove('vc_count_a');

    await expectLater(AuthService().verifyPin(pin), throwsA(isA<VaultTamperedError>()));
  });

  test('an unreadable count record counts as removed', () async {
    await storage.addEntry(VaultEntry(id: '2', title: 'Mail', username: 'ada', password: 'pw2', category: 'Email'));
    await AuthService().logout();
    harness.secureStorage['vc_count_a'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

    await expectLater(AuthService().verifyPin(pin), throwsA(isA<VaultTamperedError>()));
  });

  test('a crash between the very first write and its count still opens', () async {
    // The one moment a record can legitimately be missing: a vault written
    // exactly once, whose count never reached secure storage. Made here by
    // putting back the first copy and removing the record.
    await harness.tearDown();
    harness = RenderHarness();
    await harness.setUp(pin: pin);
    if (storage.debugOpenCount != 1) {
      markTestSkipped('this set-up writes the vault more than once');
      return;
    }
    await AuthService().logout();
    harness.secureStorage.remove('vc_count_a');
    expect(await AuthService().verifyPin(pin), isTrue);
  });
}
