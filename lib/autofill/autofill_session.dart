import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';

/// Holds the master key for one autofill, without keeping the vault open.
///
/// Every fill is unlocked for, by PIN or fingerprint: putting a password
/// into another app is the step worth checking. The key is held from that
/// unlock until the fill (AutofillScreen ends the session before handing
/// the password over), and at most for [window], so a list left on screen
/// does not keep it for ever.
///
/// The encrypted database is closed between reading the list and filling,
/// not left open. Only the key stays, in memory, in the engine the autofill
/// screen runs in.
class AutofillSession {
  AutofillSession._();

  static final AutofillSession instance = AutofillSession._();

  /// The longest one unlock is good for, if nothing is filled. Short.
  static const Duration window = Duration(minutes: 3);

  Timer? _expiry;
  DateTime? _expiresAt;

  bool get isLive {
    final at = _expiresAt;
    if (at == null) return false;
    if (DateTime.now().isAfter(at)) return false;
    // The decoy vault gets a session like any other. If it did not, a second
    // fill asking for the PIN again would tell an observer which vault was
    // open.
    return AuthService().isAuthenticated;
  }

  /// Starts the window after a successful unlock.
  void begin() {
    _expiry?.cancel();
    _expiresAt = DateTime.now().add(window);
    _expiry = Timer(window, () => end());
  }

  /// Closes the database but keeps the key for the rest of the window, which
  /// is what releases the vault lock so the main app can open it again.
  ///
  /// The autofill screen reads what it needs and calls this straight away,
  /// and again on every way out of the screen. A vault left open here used
  /// to lock the main app out, and to go on showing entries as they were
  /// when it was opened, missing anything added in the main app since.
  Future<void> parkUntilNextFill() => _serially(_park);

  /// Reopens the vault for a fill. False means the window has gone, or
  /// another isolate holds the vault right now.
  Future<bool> resume() => _serially(_resume);

  /// Opens the vault, runs [job], and closes it again, with nothing else
  /// able to open or close it in between. Null when the vault could not be
  /// opened: the window has gone, or another isolate holds it.
  Future<T?> withVault<T>(Future<T> Function() job) => _serially(() async {
        if (!await _resume()) return null;
        try {
          return await job();
        } finally {
          await _park();
        }
      });

  Future<void> _park() async {
    if (!isLive) {
      await _end();
      return;
    }
    await StorageService().suspend();
  }

  /// Always reads the vault afresh from disk. An open vault is held in
  /// memory and never sees what another isolate wrote to the file, so one
  /// that stayed open here would be out of date.
  Future<bool> _resume() async {
    if (!isLive) return false;
    final storage = StorageService();
    if (storage.isReady) await storage.suspend();
    return storage.resume();
  }

  /// Runs open and close one at a time. A request from the main app to let
  /// go can arrive while a fill is reopening the vault, and the two must not
  /// interleave.
  Future<T> _serially<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _queue = Future.value();

  /// Ends the session and forgets the key.
  Future<void> end() => _serially(_end);

  Future<void> _end() async {
    _expiry?.cancel();
    _expiry = null;
    _expiresAt = null;
    StorageService().forgetSuspended();
    await AuthService().logout();
  }

  @visibleForTesting
  DateTime? get expiresAt => _expiresAt;

  /// Starts the queue afresh in the caller's zone. A widget test runs its
  /// body under a simulated clock, and a future made there only ever reports
  /// back through that clock, so awaiting it from tearDown would never end.
  @visibleForTesting
  void resetQueueForTest() => _queue = Future.value();
}
