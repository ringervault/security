/// Merging two copies of the vault without losing anything.
///
/// Everything here is pure: no storage, no network, no clock except the one
/// passed in. That is deliberate. This is the part of sync where a mistake
/// means a password silently disappears, or one the user deleted after a
/// breach silently comes back, so every rule in it has to be testable on its
/// own.
///
/// The model is per-entry last-writer-wins. Merging whole files instead would
/// mean an edit on the phone and a different edit in the browser could not
/// both survive; merging per entry, they both do unless they touched the same
/// entry.
library;

import 'dart:convert';

/// One entry, as far as sync is concerned.
class SyncRecord {
  final String id;

  /// When this version was written. Compared across devices, which is why
  /// clock skew between devices is a known limitation: see [merge].
  final DateTime updatedAt;

  /// The entry's JSON, or null when the entry has been deleted.
  ///
  /// A deletion is kept as a record rather than as an absence. An absence is
  /// indistinguishable from "this device never had it", which is how a merge
  /// brings deleted passwords back.
  final Map<String, dynamic>? entry;

  const SyncRecord({
    required this.id,
    required this.updatedAt,
    required this.entry,
  });

  const SyncRecord.deleted({required this.id, required this.updatedAt})
      : entry = null;

  bool get isDeleted => entry == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (entry != null) 'entry': entry,
        if (entry == null) 'deleted': true,
      };

  /// Returns null for anything malformed, so one damaged record cannot stop
  /// the rest of the vault from syncing.
  static SyncRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final at = raw['updatedAt'];
    if (id is! String || id.isEmpty || at is! String) return null;

    final updatedAt = DateTime.tryParse(at);
    if (updatedAt == null) return null;

    if (raw['deleted'] == true) {
      return SyncRecord.deleted(id: id, updatedAt: updatedAt.toUtc());
    }
    final entry = raw['entry'];
    if (entry is! Map) return null;
    return SyncRecord(
      id: id,
      updatedAt: updatedAt.toUtc(),
      entry: Map<String, dynamic>.from(entry),
    );
  }

  /// A byte-for-byte stable form, used only to break exact ties.
  String canonical() => _canonicalJson(toJson());

  @override
  bool operator ==(Object other) =>
      other is SyncRecord && other.canonical() == canonical();

  @override
  int get hashCode => canonical().hashCode;
}

/// What a merge decided, and what has to happen on each side because of it.
class MergeResult {
  /// The vault as both devices should now hold it.
  final Map<String, SyncRecord> merged;

  /// Entries whose live version must be written to this device.
  final Set<String> upsertLocally;

  /// Entries that must be removed from this device.
  final Set<String> deleteLocally;

  /// Whether the remote copy is behind the merged one and needs replacing.
  final bool remoteChanged;

  const MergeResult({
    required this.merged,
    required this.upsertLocally,
    required this.deleteLocally,
    required this.remoteChanged,
  });

  bool get localChanged => upsertLocally.isNotEmpty || deleteLocally.isNotEmpty;
}

/// Picks which of two versions of one entry survives.
///
/// Later [SyncRecord.updatedAt] wins. On an exact tie the rule depends only on
/// the two records themselves, so two devices merging each other's copies
/// without talking reach the same answer:
///
///  * a deletion beats an edit, because deleting is an explicit act and an
///    edit landing in the same millisecond is far likelier to be a stale
///    copy than a real change;
///  * otherwise the greater canonical form wins, which is arbitrary but the
///    same arbitrary answer everywhere.
SyncRecord pickWinner(SyncRecord a, SyncRecord b) {
  final byTime = a.updatedAt.compareTo(b.updatedAt);
  if (byTime != 0) return byTime > 0 ? a : b;

  if (a.isDeleted != b.isDeleted) return a.isDeleted ? a : b;

  return a.canonical().compareTo(b.canonical()) >= 0 ? a : b;
}

/// Merges this device's copy with the remote one.
///
/// Winners are chosen by their stamps. Edits are stamped by a hybrid
/// logical clock (StorageService.nextStamp, and nextStamp in the extension's
/// save.js), so an edit made after seeing another device's change always
/// outranks it, even when the editing device's clock runs behind. Only two
/// edits to the same entry made on devices that had not synced in between
/// are decided by the clocks alone.
MergeResult merge({
  required Map<String, SyncRecord> local,
  required Map<String, SyncRecord> remote,
}) {
  final merged = <String, SyncRecord>{};
  final upsert = <String>{};
  final delete = <String>{};
  var remoteChanged = false;

  for (final id in {...local.keys, ...remote.keys}) {
    final mine = local[id];
    final theirs = remote[id];

    final SyncRecord winner;
    if (mine == null) {
      winner = theirs!;
    } else if (theirs == null) {
      winner = mine;
    } else {
      winner = pickWinner(mine, theirs);
    }
    merged[id] = winner;

    // This device needs to change only if it did not already hold the winner.
    if (mine != winner) {
      if (winner.isDeleted) {
        // Nothing to remove if this device never had a live copy.
        if (mine != null && !mine.isDeleted) delete.add(id);
      } else {
        upsert.add(id);
      }
    }

    if (theirs != winner) remoteChanged = true;
  }

  return MergeResult(
    merged: merged,
    upsertLocally: upsert,
    deleteLocally: delete,
    remoteChanged: remoteChanged,
  );
}

/// How long a deletion is remembered.
///
/// A device that has been away for longer than this and still holds an entry
/// deleted elsewhere will bring it back on its next sync, because the record
/// of the deletion is gone. Long enough to cover a phone left in a drawer;
/// short enough that the file does not grow for ever.
const Duration tombstoneLifetime = Duration(days: 180);

/// Drops deletions older than [tombstoneLifetime].
Map<String, SyncRecord> pruneTombstones(
  Map<String, SyncRecord> records, {
  required DateTime now,
  Duration keepFor = tombstoneLifetime,
}) {
  final cutoff = now.toUtc().subtract(keepFor);
  return {
    for (final record in records.values)
      if (!record.isDeleted || record.updatedAt.isAfter(cutoff))
        record.id: record,
  };
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}
