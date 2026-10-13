import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/repository/vault_repository.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_container.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_engine.dart';
import 'package:ringer_vault/sync/sync_transport.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

import 'support/render_harness.dart';

/// The decoy is handed over under pressure, and the first thing the person
/// holding the phone may do is edit an entry. It has to work as it does in
/// the real vault, and what it writes has to stay in the decoy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  const decoyPin = '246801';
  final storage = StorageService();
  final repository = VaultRepository();
  late RenderHarness harness;

  VaultEntry entry(String id) =>
      VaultEntry(id: id, title: id, username: 'u', password: 'pw-$id', category: 'Banking');

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [entry('real-bank')]);
    await AuthService().setSecondaryPin(decoyPin);
    // As Settings does on making one.
    await AuthService().fillNewDecoy(const DecoyIdentity(name: 'Sam Lee', email: 'sam@example.com'));
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue);
    expect(AuthService().isDecoyMode, isTrue);
  });

  tearDown(() => harness.tearDown());

  Map<String, VaultEntry> byId() => {for (final e in storage.getEntries()) e.id: e};

  /// Add one, change one of the filler entries, delete another.
  Future<(String, String)> editTheDecoy() async {
    final filler = storage.getEntries();
    expect(filler.length, greaterThan(2), reason: 'a decoy is filled when made');
    final changed = filler[0].id;
    final deleted = filler[1].id;
    await repository.addEntry(entry('decoy-new'));
    await repository.updateEntry(filler[0].copyWith(password: 'changed in the decoy'));
    await repository.deleteEntry(deleted);
    return (changed, deleted);
  }

  test('adding, changing and deleting work, and are there on the next unlock', () async {
    final (changed, deleted) = await editTheDecoy();
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue);

    final entries = byId();
    expect(entries['decoy-new']?.password, 'pw-decoy-new');
    expect(entries[changed]?.password, 'changed in the decoy');
    expect(entries.containsKey(deleted), isFalse);
    expect(entries.containsKey('real-bank'), isFalse);
  });

  test('the real vault is untouched, down to its bytes in the file', () async {
    Future<List<int>> realSlotBytes() async {
      final bytes = await harness.file(containerFileName).readAsBytes();
      final size = (bytes.length - headerBytes) ~/ 2;
      return bytes.sublist(headerBytes + realSlot * size, headerBytes + (realSlot + 1) * size);
    }

    final before = await realSlotBytes();
    await editTheDecoy();
    expect(await realSlotBytes(), before);

    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(byId().keys, {'real-bank'});
    expect(storage.deletions, isEmpty, reason: 'no tombstone for the decoy\'s delete');
  });

  test('the vault file stays the same size', () async {
    final before = await harness.file(containerFileName).length();
    await editTheDecoy();
    expect(await harness.file(containerFileName).length(), before);
  });

  test('nothing is synced: sync stops before reaching Drive', () async {
    await editTheDecoy();
    final drive = _Untouchable();
    final engine = SyncEngine(
      transport: drive,
      vault: StorageSyncVault(),
      cipher: SyncCipher('a long enough sync passphrase'),
      deviceId: 'phone',
      isStrictOffline: () => false,
      isDecoy: () => AuthService().isDecoyMode,
    );
    await expectLater(engine.run(), throwsA(isA<SyncBlocked>()));
    expect(drive.calls, isEmpty);
  });

  test('the decoy\'s own activity shows its edits, and the real one\'s does not', () async {
    await editTheDecoy();
    expect(storage.vaultLog.map((l) => l['action']),
        containsAll(['Entry Added', 'Entry Updated', 'Entry Deleted']));
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.vaultLog.map((l) => l['details']).join(' '), isNot(contains('decoy-new')));
  });
}

/// A Google Drive that records being asked anything at all.
class _Untouchable implements SyncTransport {
  final calls = <String>[];

  @override
  Future<RemoteInfo?> info() async {
    calls.add('info');
    return null;
  }

  @override
  Future<String> fetch(RemoteInfo info, {ByteProgress? onBytes}) async {
    calls.add('fetch');
    throw const SyncTransportError('not expected');
  }

  @override
  Future<String> upload(String content, {required String? ifVersion}) async {
    calls.add('upload');
    return '1';
  }

  @override
  Future<void> delete() async => calls.add('delete');
}
