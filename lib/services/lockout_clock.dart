import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The clock wrong-attempt lockouts are measured on.
///
/// The phone's date and time can be changed in Settings, so a lockout timed
/// by it could be ended early by moving the clock forward. Android's time
/// since boot cannot be changed, so a lockout is timed on that, together
/// with which boot it was (a restart starts the time since boot again, and
/// the lockout then runs its full length again). Without the Android side
/// (tests, other platforms) only the wall clock is known.
class LockoutClock {
  static const _channel = MethodChannel('ringer_vault/session');

  /// For tests: the clock to read instead of the platform's.
  @visibleForTesting
  static LockoutTime Function()? debugNow;

  static Future<LockoutTime> now() async {
    final forced = debugNow;
    if (forced != null) return forced();
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('clock');
      final elapsed = raw?['elapsedMs'];
      final boot = raw?['boot'];
      if (elapsed is int) {
        return LockoutTime(DateTime.now(), elapsedMs: elapsed, boot: boot is int ? boot : null);
      }
    } catch (_) {
      // No Android side: the wall clock alone.
    }
    return LockoutTime(DateTime.now());
  }
}

/// One reading of [LockoutClock].
class LockoutTime {
  final DateTime wall;

  /// Milliseconds since boot, or null without the Android side.
  final int? elapsedMs;

  /// Which boot this is, or null when Android does not say.
  final int? boot;

  const LockoutTime(this.wall, {this.elapsedMs, this.boot});
}
