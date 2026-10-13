import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

/// What the real vault will take from another device. Anything it cannot
/// build into an entry, under the id it was filed under, refuses the sync.
void main() {
  final vault = StorageSyncVault();
  Map<String, dynamic> entry(String id) => {
        'id': id,
        'title': 'Bank',
        'username': 'ada',
        'password': 'pw',
        'category': 'Banking',
        'createdAt': '2026-09-01T00:00:00Z',
        'updatedAt': '2026-09-01T00:00:00Z',
      };
  SyncRecord rec(String id, Map<String, dynamic> e) =>
      SyncRecord(id: id, updatedAt: DateTime.utc(2026, 9, 1), entry: e);

  test('a whole entry under its own id is taken', () {
    expect(vault.canStore(rec('a', entry('a'))), isTrue);
  });

  test('an entry filed under another id is not', () {
    expect(vault.canStore(rec('a', entry('b'))), isFalse,
        reason: 'it would overwrite entry b');
  });

  test('wrong types or missing fields are not', () {
    expect(vault.canStore(rec('a', {...entry('a'), 'password': 5})), isFalse);
    expect(vault.canStore(rec('a', {...entry('a'), 'createdAt': 'soon'})), isFalse);
    expect(vault.canStore(rec('a', {...entry('a')}..remove('title'))), isFalse);
    expect(vault.canStore(rec('a', {...entry('a'), 'autofillTargets': 'site:x'})), isFalse);
  });

  test('a deletion is never stored as an entry', () {
    expect(vault.canStore(SyncRecord.deleted(id: 'a', updatedAt: DateTime.utc(2026))), isFalse);
  });
}
