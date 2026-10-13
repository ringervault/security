import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

import 'support/render_harness.dart';

/// A phone whose clock runs years behind must still win with an edit it
/// makes after syncing another device's change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RenderHarness harness;
  final storage = StorageService();
  final ahead = DateTime.utc(2035, 1, 1);

  VaultEntry entry(String id, String password, DateTime at) => VaultEntry(
      id: id, title: id, username: 'u', password: password, category: 'Banking', updatedAt: at);

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(entries: const []);
  });
  tearDown(() => harness.tearDown());

  test('an edit made here is stamped after anything already synced', () async {
    // Another device, its clock in 2035, synced this entry in.
    await storage.applySyncedEntry(entry('a', 'from-ahead', ahead));

    final edited = storage.getEntries().single..password = 'edited-here';
    await storage.updateEntry(edited);

    expect(storage.getEntries().single.updatedAt.isAfter(ahead), isTrue);
  });

  test('a deletion made here is stamped after anything already synced', () async {
    await storage.applySyncedEntry(entry('a', 'from-ahead', ahead));
    await storage.deleteEntry('a');
    expect(storage.deletions['a']!.isAfter(ahead), isTrue);
  });

  test('so the merge keeps the later edit, not the one from the faster clock', () async {
    final theirs = SyncRecord(
      id: 'a', updatedAt: ahead, entry: entry('a', 'from-ahead', ahead).toJson());
    await storage.applySyncedEntry(entry('a', 'from-ahead', ahead));
    final edited = storage.getEntries().single..password = 'edited-here';
    await storage.updateEntry(edited);

    final mine = StorageSyncVault(storage).snapshot();
    final result = merge(local: mine, remote: {'a': theirs});
    expect(result.merged['a']!.entry!['password'], 'edited-here');
    expect(result.remoteChanged, isTrue);
  });

  test('with nothing ahead, an edit is simply stamped now', () async {
    final before = DateTime.now().toUtc();
    await storage.addEntry(entry('b', 'p', DateTime.utc(2000)));
    final at = storage.getEntries().single.updatedAt;
    expect(at.isBefore(before), isFalse);
    expect(at.isBefore(DateTime.now().toUtc().add(const Duration(seconds: 1))), isTrue);
  });
}
