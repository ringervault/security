import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:crypto/crypto.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_payload.dart';
import 'package:ringer_vault/sync/sync_transport.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

/// Reports how far a sync has got, from 0 to 1, and what it is doing.
typedef SyncProgress = void Function(double fraction, String stage);

/// What one sync did.
class SyncOutcome {
  /// Entries written to this device.
  final int pulled;

  /// Entries removed from this device because they were deleted elsewhere.
  final int removed;

  /// Whether the copy in Drive was replaced.
  final bool pushed;

  /// Nothing had changed on either side, so nothing was downloaded.
  final bool upToDate;

  /// How many read-merge-write rounds it took. More than one means another
  /// device wrote at the same moment.
  final int attempts;

  const SyncOutcome({
    required this.pulled,
    required this.removed,
    required this.pushed,
    required this.attempts,
    this.upToDate = false,
  });
}

/// Where the last successful sync left both sides, so the next one can tell
/// in a single request that nothing has changed.
class SyncMark {
  final String version;
  final String localHash;

  /// The highest generation of the Drive copy this device has accepted.
  /// A copy with a lower one is an older file put back: see [SyncRolledBack].
  final int generation;

  const SyncMark({required this.version, required this.localHash, this.generation = 0});
}

abstract class SyncMarkStore {
  Future<SyncMark?> load();
  Future<void> save(SyncMark mark);
}

/// Sync was not attempted, and why. Nothing remote was touched.
class SyncBlocked implements Exception {
  final String reason;
  const SyncBlocked(this.reason);

  @override
  String toString() => reason;
}

/// The backup this device was syncing with has been deleted, from another
/// device or from Drive itself.
class SyncRemoteGone implements Exception {
  const SyncRemoteGone();

  @override
  String toString() =>
      'The backup in Google Drive was deleted, probably from another device. '
      'Sync has been turned off here, and the entries on this device are '
      'untouched. Sign in again to start a new backup.';
}

/// The copy in Drive is older than one this device already synced with:
/// someone with access to the Drive account put back an earlier version of
/// the file (Drive keeps them), or restored it from a backup. Nothing was
/// merged or written on either side.
///
/// Merging it would bring back passwords deleted since, and old passwords
/// changed since, and the next write would make the older state current
/// everywhere. Nothing short of the passphrase can make a copy look newer,
/// so this is only ever an old file, never a forged one.
class SyncRolledBack implements Exception {
  /// The Drive copy's generation, and the highest this device accepted.
  final int found;
  final int seen;
  const SyncRolledBack({required this.found, required this.seen});

  @override
  String toString() =>
      'The copy in Google Drive is older than one this phone already synced '
      'with (version $found, after $seen). Someone may have put back an '
      'earlier copy of the file. Nothing was changed on either side. If you '
      'restored an older copy on purpose, enter your sync passphrase to use '
      'it.';
}

/// Kept colliding with another device writing at the same time.
class SyncGaveUp implements Exception {
  const SyncGaveUp();

  @override
  String toString() =>
      'Another device kept syncing at the same moment. Nothing was lost; '
      'try again shortly.';
}

/// What to do with a Drive copy of generation [found], having accepted
/// [seen]: null to refuse it as an older copy put back, otherwise the
/// generation to write next, above everything either side has seen
/// (including an older copy taken on purpose, so no other device refuses
/// what this one wrote). The extension's rollback.js answers the same, and
/// test/fixtures/rollback_cases.json holds the cases both must agree on.
int? generationStep({required int found, required int seen, bool acceptOlder = false}) {
  if (found < seen && !acceptOlder) return null;
  return (found > seen ? found : seen) + 1;
}

/// Read the remote copy, merge, write both sides.
///
/// Every round starts from a fresh look at the remote, and applies its merge
/// to this device whether or not the upload succeeds. That is what makes a
/// lost race harmless: this device's own changes are always kept here until
/// they are in a remote copy, so if another device's write lands on top of
/// ours, the next round simply merges them in again.
///
/// For speed, the two slow halves of a round run side by side: writing the
/// merged entries to this device's storage, and encrypting and uploading them
/// to Drive. Neither depends on the other, and either order is safe.
class SyncEngine {
  final SyncTransport transport;
  final SyncVault vault;
  final SyncCipher cipher;
  final String deviceId;

  /// Read at the moment of syncing, not when the engine is built, so turning
  /// Strict Offline Mode on stops the very next attempt.
  final bool Function() isStrictOffline;
  final bool Function() isDecoy;

  final SyncMarkStore? marks;
  final DateTime Function() clock;
  final int maxAttempts;

  SyncEngine({
    required this.transport,
    required this.vault,
    required this.cipher,
    required this.deviceId,
    required this.isStrictOffline,
    required this.isDecoy,
    this.marks,
    DateTime Function()? clock,
    this.maxAttempts = 3,
  }) : clock = clock ?? (() => DateTime.now().toUtc());

  /// [acceptOlder] lets one run use a Drive copy older than the last one
  /// accepted ([SyncRolledBack]), after the user has re-entered the sync
  /// passphrase to say they put it there on purpose.
  Future<SyncOutcome> run({SyncProgress? onProgress, bool acceptOlder = false}) async {
    // Progress never goes backwards, including across a retry, because a bar
    // that jumps back looks like something went wrong.
    var shown = 0.0;
    void report(double fraction, String stage) {
      if (fraction > shown) shown = fraction.clamp(0.0, 1.0);
      onProgress?.call(shown, stage);
    }

    // Gates come before any network call. Strict Offline Mode is the user
    // saying "nothing leaves this device", and that has to mean nothing,
    // including a request that would reveal the device is syncing.
    if (isStrictOffline()) {
      throw const SyncBlocked(
        'Strict Offline Mode is on, so sync is paused. Turn it off in '
        'Settings to sync.',
      );
    }
    if (isDecoy()) {
      // Syncing the decoy would either publish it or overwrite the real
      // vault's copy with it.
      throw const SyncBlocked('Sync is not available here.');
    }

    final mark = await marks?.load();

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      report(0.05, 'Checking Google Drive');
      final info = await transport.info();

      // Having synced before and now finding nothing means someone deleted
      // the backup on purpose. Recreating it from this device would undo that
      // decision without asking.
      if (info == null && mark != null) throw const SyncRemoteGone();

      final local = vault.snapshot();
      final localHash = await compute(hashOf, local);
      if (info != null &&
          mark != null &&
          info.version == mark.version &&
          localHash == mark.localHash) {
        report(1, 'Up to date');
        return SyncOutcome(
          pulled: 0,
          removed: 0,
          pushed: false,
          attempts: attempt,
          upToDate: true,
        );
      }

      // A passphrase that does not open the remote copy stops everything.
      // That copy is another device's data; replacing it with ours because
      // we could not read it would destroy it.
      var remote = <String, SyncRecord>{};
      var remoteGeneration = 0;
      if (info != null) {
        report(0.1, 'Downloading backup');
        final content = await transport.fetch(
          info,
          onBytes: (received, total) {
            if (total != null && total > 0) {
              report(0.1 + 0.3 * (received / total), 'Downloading backup');
            }
          },
        );
        report(0.42, cipher.isWarm ? 'Opening backup' : 'Unlocking backup');
        final payload = await SyncPayload.decrypt(content, cipher);
        final step = generationStep(
          found: payload.generation,
          seen: mark?.generation ?? 0,
          acceptOlder: acceptOlder,
        );
        if (step == null) {
          throw SyncRolledBack(found: payload.generation, seen: mark?.generation ?? 0);
        }
        remote = payload.records;
        remoteGeneration = payload.generation;
      }
      final seenGeneration = mark?.generation ?? 0;
      final nextGeneration =
          generationStep(found: remoteGeneration, seen: seenGeneration, acceptOlder: true)!;

      report(0.55, 'Merging');
      // Comparing every entry on both sides is the other heavy step, so it
      // runs off the thread that draws the screen too.
      final (result, merged, mergedDiffers) =
          await compute(_plan, (local, remote, clock()));
      // An older copy taken on purpose is always written back, numbered
      // above everything seen, so other devices take it too.
      final needsUpload = mergedDiffers || (acceptOlder && remoteGeneration < seenGeneration);

      // Nothing is written anywhere unless every entry coming in can be.
      final unreadable = result.upsertLocally.where((id) => !vault.canStore(result.merged[id]!)).length;
      if (unreadable > 0) {
        throw SyncPayloadError(
          'The synced copy has ${unreadable == 1 ? 'an entry' : '$unreadable entries'} '
          'this app cannot read, so it was not used. Nothing was changed on '
          'either side.',
        );
      }

      final localWrites =
          result.upsertLocally.length + result.deleteLocally.length;
      var localDone = 0;
      var uploaded = !needsUpload;
      void reportSaving() {
        final localPart = localWrites == 0 ? 1.0 : localDone / localWrites;
        final remotePart = uploaded ? 1.0 : 0.0;
        report(
          0.6 + 0.2 * localPart + 0.18 * remotePart,
          'Saving to this device and Google Drive',
        );
      }

      Future<void> applyLocally() async {
        for (final id in result.upsertLocally) {
          await vault.applyEntry(result.merged[id]!);
          localDone++;
          reportSaving();
        }
        for (final id in result.deleteLocally) {
          await vault.applyDeletion(result.merged[id]!);
          localDone++;
          reportSaving();
        }
        await vault.replaceDeletions({
          for (final r in merged.values)
            if (r.isDeleted) r.id: r.updatedAt,
        });
      }

      Future<String?> uploadRemote() async {
        if (!needsUpload) return info?.version;
        final payload = SyncPayload(
          records: merged,
          writtenBy: deviceId,
          writtenAt: clock(),
          generation: nextGeneration,
        );
        final version = await transport.upload(
          await payload.encrypt(cipher),
          ifVersion: info?.version,
        );
        uploaded = true;
        reportSaving();
        return version;
      }

      final localJob = applyLocally();
      // Its error, if any, is taken up below once the local writes are done;
      // without ignore() an upload failing first would be reported as
      // unhandled meanwhile, as if the app had crashed.
      final remoteJob = uploadRemote()..ignore();
      String? version;
      try {
        await localJob;
        version = await remoteJob;
      } on SyncConflict {
        // The local writes are kept: they are correct whatever the remote now
        // holds, and the next round merges on top of them.
        continue;
      }

      if (version != null) {
        await marks?.save(
          SyncMark(
            version: version,
            localHash: await compute(hashOf, vault.snapshot()),
            generation: needsUpload ? nextGeneration : remoteGeneration,
          ),
        );
      }

      report(1, 'Done');
      return SyncOutcome(
        pulled: result.upsertLocally.length,
        removed: result.deleteLocally.length,
        pushed: needsUpload,
        attempts: attempt,
      );
    }

    throw const SyncGaveUp();
  }

  /// A fingerprint of a vault's contents, for noticing that nothing changed.
  static String hashOf(Map<String, SyncRecord> records) {
    final ids = records.keys.toList()..sort();
    final canonical = ids.map((id) => records[id]!.canonical()).join('\n');
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  /// The merge, the tombstones it keeps, and whether the remote copy needs
  /// replacing. Pure, and run on a background isolate.
  static (MergeResult, Map<String, SyncRecord>, bool) _plan(
    (Map<String, SyncRecord>, Map<String, SyncRecord>, DateTime) args,
  ) {
    final (local, remote, now) = args;
    final result = merge(local: local, remote: remote);
    final merged = pruneTombstones(result.merged, now: now);
    return (result, merged, !_same(merged, remote));
  }

  static bool _same(Map<String, SyncRecord> a, Map<String, SyncRecord> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
