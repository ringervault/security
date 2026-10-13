import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_merge.dart';

import 'support/render_harness.dart';

/// One entry stamped far in the future by a device with a wrong clock must
/// not drag every later edit that far forward, nor stay for ever as a
/// deletion that never grows old.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RenderHarness harness;
  final storage = StorageService();
  final farAhead = DateTime.now().toUtc().add(const Duration(days: 3650));

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: '482916');
    await storage.applySyncedEntry(VaultEntry(
      id: 'future', title: 'From a wrong clock', username: 'u', password: 'p',
      category: 'Social', updatedAt: farAhead, createdAt: farAhead,
    ));
  });
  tearDown(() => harness.tearDown());

  test('an unrelated edit is stamped now, not after the far-future entry', () async {
    await storage.addEntry(VaultEntry(id: 'mine', title: 'Mine', username: 'u', password: 'p', category: 'Social'));
    final mine = storage.getEntries().firstWhere((e) => e.id == 'mine');
    expect(mine.updatedAt.difference(DateTime.now().toUtc()).inMinutes.abs(), lessThan(5));
  });

  test('editing the far-future entry itself still outranks it', () async {
    final future = storage.getEntries().firstWhere((e) => e.id == 'future');
    await storage.updateEntry(future.copyWith(password: 'new'));
    final edited = storage.getEntries().firstWhere((e) => e.id == 'future');
    expect(edited.updatedAt.isAfter(farAhead), isTrue);
  });

  test('a stamp a little ahead, from a fast clock, is still followed', () async {
    final soon = DateTime.now().toUtc().add(const Duration(hours: 2));
    await storage.applySyncedEntry(VaultEntry(
      id: 'fast', title: 'Fast clock', username: 'u', password: 'p',
      category: 'Social', updatedAt: soon, createdAt: soon,
    ));
    await storage.addEntry(VaultEntry(id: 'mine', title: 'Mine', username: 'u', password: 'p', category: 'Social'));
    final mine = storage.getEntries().firstWhere((e) => e.id == 'mine');
    expect(mine.updatedAt.isAfter(soon), isTrue);
  });

  test('a deletion stamped far ahead is pruned; an ordinary recent one is kept', () {
    final now = DateTime.now().toUtc();
    final kept = pruneTombstones({
      'ahead': SyncRecord.deleted(id: 'ahead', updatedAt: now.add(const Duration(days: 30))),
      'recent': SyncRecord.deleted(id: 'recent', updatedAt: now.subtract(const Duration(days: 3))),
      'old': SyncRecord.deleted(id: 'old', updatedAt: now.subtract(const Duration(days: 400))),
    }, now: now);
    expect(kept.keys, ['recent']);
  });
}
