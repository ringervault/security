import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

import 'support/render_harness.dart';

/// Deletions have to be remembered by the real vault for sync to work: an
/// entry that is simply gone looks, to a merge, exactly like one this device
/// never had, and the other device's copy brings it back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  late RenderHarness harness;
  final storage = StorageService();

  VaultEntry entry(String id, {DateTime? updatedAt}) => VaultEntry(
        id: id,
        title: id,
        username: 'u',
        password: 'pw-$id',
        category: 'Banking',
        updatedAt: updatedAt,
      );

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [entry('a'), entry('b')]);
  });

  tearDown(() => harness.tearDown());

  test('deleting an entry records when it happened', () async {
    final before = DateTime.now().toUtc();
    await storage.deleteEntry('a');

    final deletions = storage.deletions;
    expect(deletions.keys, ['a']);
    expect(deletions['a']!.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse);
  });

  test('clearing the vault records every entry it removed', () async {
    await storage.deleteAllEntries();
    expect(storage.deletions.keys.toSet(), {'a', 'b'});
  });

  test('deletions survive locking and unlocking', () async {
    await storage.deleteEntry('a');
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);

    expect(storage.deletions.keys, ['a']);
  });

  test('a synced entry keeps the time it was written elsewhere', () async {
    // Stamping it with "now" would make it look newer than it is, and let it
    // beat a genuinely later edit made on another device.
    final elsewhere = DateTime.utc(2020, 1, 1);
    await storage.applySyncedEntry(entry('c', updatedAt: elsewhere));

    final stored = storage.getEntries().firstWhere((e) => e.id == 'c');
    expect(stored.updatedAt.toUtc(), elsewhere);
  });

  test('a synced entry clears an older deletion of the same id', () async {
    await storage.deleteEntry('a');
    await storage.applySyncedEntry(entry('a', updatedAt: DateTime.utc(2030)));

    expect(storage.deletions.containsKey('a'), isFalse);
    expect(storage.getEntries().any((e) => e.id == 'a'), isTrue);
  });

  test('a synced deletion keeps the time it happened elsewhere', () async {
    final elsewhere = DateTime.utc(2021, 6, 1);
    await storage.applySyncedDeletion('a', elsewhere);

    expect(storage.deletions['a'], elsewhere);
    expect(storage.getEntries().any((e) => e.id == 'a'), isFalse);
  });

  test('the sync view of the vault includes live entries and deletions',
      () async {
    await storage.deleteEntry('b');
    final snapshot = StorageSyncVault(storage).snapshot();

    expect(snapshot['a']!.isDeleted, isFalse);
    expect(snapshot['a']!.entry!['password'], 'pw-a');
    expect(snapshot['b']!.isDeleted, isTrue);
  });

  test('re-keying the vault keeps its deletions readable', () async {
    await storage.deleteEntry('a');
    final current = storage.activeMasterKey!;
    final next = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );

    await storage.rekeyVault(
      currentMasterKey: current,
      newMasterKey: next,
      isDecoy: false,
    );

    expect(storage.deletions.keys, ['a']);
  });

  test('destroying the vaults destroys the deletion record too', () async {
    // A list of deleted IDs is itself information about the vault.
    await storage.deleteEntry('a');
    await storage.destroyAllVaults();

    // It lives in the vault file, which goes whole.
    final leftovers = Directory(harness.hiveDirPath)
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.startsWith('vault.rvc') || n.startsWith('vault2'));
    expect(leftovers, isEmpty);
  });

  test('the decoy vault keeps no deletion record', () async {
    // It never syncs, and a second file beside it would be a way to tell the
    // two vaults apart.
    await StorageService().close();
    final decoyKey = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await storage.openVault(masterKey: decoyKey, isDecoy: true);
    await storage.addEntry(entry('d'));
    await storage.deleteEntry('d');

    expect(storage.deletions, isEmpty);
  });

  test('a deletion record round-trips through a merge', () async {
    // End to end: a real deletion here, a stale copy elsewhere, and the
    // merge must keep the deletion.
    await storage.deleteEntry('a');
    final local = StorageSyncVault(storage).snapshot();
    final stale = {
      'a': SyncRecord(
        id: 'a',
        updatedAt: DateTime.utc(2000),
        entry: entry('a').toJson(),
      ),
    };

    final result = merge(local: local, remote: stale);
    expect(result.merged['a']!.isDeleted, isTrue);
    expect(result.upsertLocally, isNot(contains('a')));
  });
}
