import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_merge.dart';

/// What the sync engine needs from the vault, and nothing more.
abstract class SyncVault {
  /// Every live entry and every remembered deletion.
  Map<String, SyncRecord> snapshot();

  /// Whether [record], a live entry from another device, can be stored
  /// here as it is. Asked of every entry a sync would write before it
  /// writes any, so a damaged copy is refused whole rather than half
  /// applied.
  bool canStore(SyncRecord record);

  Future<void> applyEntry(SyncRecord record);
  Future<void> applyDeletion(SyncRecord record);

  /// Replaces the deletion record, after old deletions have been pruned.
  Future<void> replaceDeletions(Map<String, DateTime> deletions);
}

/// The real vault.
class StorageSyncVault implements SyncVault {
  final StorageService _storage;

  StorageSyncVault([StorageService? storage])
      : _storage = storage ?? StorageService();

  @override
  Map<String, SyncRecord> snapshot() {
    final records = <String, SyncRecord>{
      for (final entry in _storage.getEntries())
        entry.id: SyncRecord(
          id: entry.id,
          updatedAt: entry.updatedAt.toUtc(),
          entry: entry.toJson(),
        ),
    };
    for (final deletion in _storage.deletions.entries) {
      // A live entry with the same id wins locally: it was re-created after
      // the deletion, and the vault only holds one or the other.
      records.putIfAbsent(
        deletion.key,
        () => SyncRecord.deleted(id: deletion.key, updatedAt: deletion.value),
      );
    }
    return records;
  }

  @override
  bool canStore(SyncRecord record) {
    final json = record.entry;
    if (json == null) return false;
    try {
      // Built for real, as applyEntry will, and under its own id: an entry
      // filed under one id but naming another would overwrite the other.
      final entry = VaultEntry.fromJson(json);
      return entry.id == record.id && entry.id.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> applyEntry(SyncRecord record) =>
      _storage.applySyncedEntry(VaultEntry.fromJson(record.entry!));

  @override
  Future<void> applyDeletion(SyncRecord record) =>
      _storage.applySyncedDeletion(record.id, record.updatedAt);

  @override
  Future<void> replaceDeletions(Map<String, DateTime> deletions) =>
      _storage.replaceDeletions(deletions);
}
