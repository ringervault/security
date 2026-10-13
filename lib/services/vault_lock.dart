import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Stops the vault being opened twice at once.
///
/// Autofill runs in its own Flutter engine, which is its own isolate with its
/// own copy of every singleton. Hive has no idea about that: two isolates
/// appending to the same box file is how a vault gets corrupted, and a
/// corrupted vault here means data nobody can recover.
///
/// The lock is a small file both isolates can see. It is advisory, and the
/// window it leaves is a few milliseconds wide, which is a great deal better
/// than the unbounded overlap without it.
///
/// It records the process as well as the isolate. Both engines live in the
/// app's one process, so a lock written by a different process belongs to one
/// that has ended: Android killed it, or the user swiped the app away while
/// the vault was open. Such a lock is taken over at once. Without the process
/// check it was honoured for the full [staleAfter], and the lock screen
/// refused a correct PIN for up to fifteen minutes after every such exit.
class VaultLock {
  VaultLock._();

  static const String _fileName = 'vault.open';

  /// Identifies this isolate. Regenerated per isolate, which is what makes
  /// "is this lock mine" answerable.
  static final String _owner =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  /// A lock held by another isolate in this same process, older than this,
  /// is treated as abandoned. That only happens if an engine leaked the vault
  /// without closing it; a lock from another process never waits this long.
  static const Duration staleAfter = Duration(minutes: 15);

  static File? _file;
  static bool _held = false;

  static bool get isHeldByThisIsolate => _held;

  /// Asks whoever holds the lock in this process to close the vault, and
  /// completes once they have. Set only in the main app.
  ///
  /// The only other holder is the autofill screen, and while the main app is
  /// in front nobody is looking at that screen. So the main app always wins:
  /// before this, a vault the autofill screen had not closed kept the main
  /// app out for up to [staleAfter].
  static Future<bool> Function()? askHolderToRelease;

  /// [acquire], and if that fails, one [askHolderToRelease] and a retry.
  static Future<bool> acquireOrAsk() async {
    if (await acquire()) return true;
    final ask = askHolderToRelease;
    if (ask == null) return false;
    try {
      if (!await ask()) return false;
    } catch (_) {
      return false;
    }
    return acquire();
  }

  /// For tests, on a phone as well as off one: the folder to keep the lock
  /// in instead of the app's own.
  @visibleForTesting
  static String? debugDirectory;

  static Future<File?> _lockFile() async {
    if (_file != null) return _file;
    try {
      final dir = debugDirectory ?? (await getApplicationDocumentsDirectory()).path;
      return _file = File('$dir/$_fileName');
    } catch (_) {
      // No documents directory, as in a plain unit test. Nothing to lock.
      return null;
    }
  }

  /// Takes the lock, or reports who has it.
  ///
  /// Returns true when the vault may be opened.
  static Future<bool> acquire() async {
    final file = await _lockFile();
    if (file == null) return true;

    try {
      if (await file.exists()) {
        final holder = _Holder.parse(await file.readAsString());
        if (holder != null && holder.blocks(currentPid: pid, owner: _owner)) {
          return false;
        }
      }

      await file.writeAsString(_Holder.describe(pid, _owner), flush: true);
      _held = true;
      return true;
    } catch (_) {
      // Never let a lock failure stop someone reaching their own vault.
      return true;
    }
  }

  /// Releases the lock, but only if this isolate is the one holding it.
  static Future<void> release() async {
    final file = await _lockFile();
    if (file == null) {
      _held = false;
      return;
    }

    try {
      if (await file.exists()) {
        final holder = _Holder.parse(await file.readAsString());
        if (holder != null && holder.pid == pid && holder.owner == _owner) {
          await file.delete();
        }
      }
    } catch (_) {
      // Best effort. A leftover lock goes stale on its own.
    } finally {
      _held = false;
    }
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    _held = false;
    try {
      final file = _file;
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {
      // The directory may already be gone between tests.
    }
    // Drop the cached path as well, or the next test keeps writing into the
    // previous test's temporary directory.
    _file = null;
  }

  /// Used by tests to simulate another isolate in this process holding the
  /// vault, which is the one case that must still block.
  @visibleForTesting
  static Future<void> takeAsOtherIsolate({Duration age = Duration.zero}) async {
    final file = await _lockFile();
    if (file == null) return;
    await file.writeAsString(
      _Holder.describe(pid, 'another-isolate', at: DateTime.now().subtract(age)),
      flush: true,
    );
  }

  /// Used by tests to simulate a lock left behind by a process that ended
  /// while the vault was open.
  @visibleForTesting
  static Future<void> takeAsEndedProcess() async {
    final file = await _lockFile();
    if (file == null) return;
    await file.writeAsString(
      _Holder.describe(pid + 1, 'ended-process'),
      flush: true,
    );
  }

  /// Used by tests to plant a lock in the format written before the process
  /// was recorded.
  @visibleForTesting
  static Future<void> takeInOldFormat() async {
    final file = await _lockFile();
    if (file == null) return;
    await file.writeAsString(
      'old-owner ${DateTime.now().toIso8601String()}',
      flush: true,
    );
  }
}

/// Who the lock file says has the vault open.
class _Holder {
  final int pid;
  final String owner;
  final DateTime since;

  const _Holder(this.pid, this.owner, this.since);

  static String describe(int pid, String owner, {DateTime? at}) =>
      '$pid $owner ${(at ?? DateTime.now()).toUtc().toIso8601String()}';

  /// Null for anything unreadable, including the older two-part format. That
  /// format could only have been written by a build this process replaced,
  /// and installing a build ends the process that ran the old one.
  static _Holder? parse(String contents) {
    final parts = contents.trim().split(' ');
    if (parts.length != 3) return null;
    final holderPid = int.tryParse(parts[0]);
    final since = DateTime.tryParse(parts[2]);
    if (holderPid == null || since == null) return null;
    return _Holder(holderPid, parts[1], since.toUtc());
  }

  /// Whether this lock stops [owner], in process [currentPid], from opening.
  bool blocks({required int currentPid, required String owner}) {
    if (pid != currentPid) return false; // That process has ended.
    if (this.owner == owner) return false; // Ours already.
    final age = DateTime.now().toUtc().difference(since);
    return age <= VaultLock.staleAfter;
  }
}

/// Thrown when the vault is already open somewhere else on this device.
class VaultBusyException implements Exception {
  @override
  String toString() => 'The vault is already open elsewhere.';
}
