import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

/// Which log an event belongs in.
///
/// The split exists because two requirements pull against each other: failed
/// unlock attempts must be recorded before any vault is open, but events that
/// name vault contents must be unreadable without that vault's key, and an
/// event revealing that a decoy vault was opened must not be visible from the
/// real vault, or vice versa.
enum LogScope {
  /// Device-scoped, readable before unlock, encrypted with a keystore-held
  /// key. Must never carry vault contents, and must never mention the decoy: /// a device-wide record of "Decoy Vault Access" would advertise that a decoy
  /// exists, which is the one thing the feature has to hide.
  security,

  /// Kept inside the open vault's part of the vault file (StorageService),
  /// so it is encrypted with that vault and invisible from the other one,
  /// and no separate file says how many vaults there are.
  vault,
}

/// How long an ordinary event is kept.
const Duration logLifetime = Duration(days: 15);

/// How long something done despite a warning is kept: a fill or save into a
/// look-alike site, say. Fraud on an account tends to come to light weeks
/// or months later, and "was I warned when I signed in there?" should still
/// have an answer then. The same as the sync's tombstoneLifetime, so the
/// app has one long period rather than two. Settings says so beside the
/// Security Log.
const Duration warningLogLifetime = Duration(days: 180);

/// Whether [log] is past its lifetime at [now].
@visibleForTesting
bool isExpired(Map log, DateTime now) {
  final time = DateTime.tryParse(log['timestamp'] as String? ?? '');
  if (time == null) return false;
  final lifetime = log['isWarning'] == true ? warningLogLifetime : logLifetime;
  return time.isBefore(now.subtract(lifetime));
}

class ActivityLogService {
  static const String _securityBoxName = 'security_log_box';

  /// The original cleartext log. Deleted rather than migrated: it holds entry
  /// titles in the open, so the goal is for it to stop existing.
  static const String _legacyBoxName = 'activity_log_box';

  static final ActivityLogService _instance = ActivityLogService._internal();
  factory ActivityLogService() => _instance;
  ActivityLogService._internal();

  final _keys = VaultKeyService();

  Box<Map>? _securityBox;

  /// Opens the device-scoped log.
  ///
  /// Lazy on purpose. Obtaining the log key touches secure storage, and on
  /// Android that work runs on the platform main thread: the same thread that
  /// composites Flutter frames. Doing it during startup blocked the first
  /// frame for seconds, which showed as a black screen that never resolved.
  /// Nothing needs this log until something is actually logged.
  Future<void> _ensureSecurityLog() async {
    if (_securityBox?.isOpen ?? false) return;

    // Best-effort: a failure here must not stop the app from starting.
    try {
      await Hive.deleteBoxFromDisk(_legacyBoxName);
    } catch (_) {
      // Never existed, or already gone.
    }

    final key = await _keys.deviceScopedKey('security_log');
    _securityBox = await Hive.openBox<Map>(
      _securityBoxName,
      encryptionCipher: HiveAesCipher(key),
    );
  }

  /// Retained for callers that want the log warmed up ahead of time. Safe to
  /// call from a background moment; never on the startup path.
  Future<void> init() => _ensureSecurityLog();

  Future<void> logActivity({
    required String action,
    String? details,
    bool isFailure = false,
    // Something done although the app warned against it, such as a fill
    // into a look-alike site. Shown with a warning mark, not a tick.
    bool isWarning = false,
    LogScope scope = LogScope.vault,
  }) async {
    if (scope == LogScope.security) await _ensureSecurityLog();

    final log = {
      'timestamp': DateTime.now().toIso8601String(),
      'action': action,
      'details': details,
      'isFailure': isFailure,
      if (isWarning) 'isWarning': true,
    };

    if (scope == LogScope.vault) {
      // No vault open means there is nothing this event could be encrypted
      // under. Dropping it is correct: writing it somewhere readable would
      // be the leak this class exists to prevent.
      final storage = StorageService();
      if (!storage.isReady) return;
      final now = DateTime.now();
      await storage.setVaultLog([
        for (final l in storage.vaultLog)
          if (!isExpired(l, now)) l,
        log,
      ]);
      return;
    }

    final box = _securityBox;
    if (box == null || !box.isOpen) return;
    await box.add(log);
    await _pruneOldLogs(box);
  }

  Future<void> _pruneOldLogs(Box<Map> box) async {
    final now = DateTime.now();
    final keysToDelete = <dynamic>[];
    for (var i = 0; i < box.length; i++) {
      final log = box.getAt(i);
      if (log != null && isExpired(log, now)) keysToDelete.add(box.keyAt(i));
    }

    if (keysToDelete.isNotEmpty) {
      await box.deleteAll(keysToDelete);
    }
  }

  /// Security events plus the open vault's events, newest first.
  ///
  /// When no vault is open this returns security events only, which is what
  /// the lock screen should be able to show.
  /// Opens the security log if it is not already up, for screens that read
  /// the log directly.
  Future<void> ensureReady() => _ensureSecurityLog();

  List<Map<String, dynamic>> getLogs() {
    final logs = <Map<String, dynamic>>[];

    final box = _securityBox;
    if (box != null && box.isOpen) {
      for (var i = 0; i < box.length; i++) {
        final item = box.getAt(i);
        if (item != null) logs.add(Map<String, dynamic>.from(item));
      }
    }
    logs.addAll(StorageService().vaultLog.map(Map<String, dynamic>.from));

    logs.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
    return logs;
  }

  Future<void> clearLogs() async {
    await _securityBox?.clear();
    await StorageService().setVaultLog([]);
  }
}
