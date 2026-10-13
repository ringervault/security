import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the fingerprint may be offered: only once the real vault has been
/// unlocked with its PIN in this run of the app, and not since the decoy was
/// opened (VaultSession.kt). The fingerprint opens the real vault alone.
///
/// Kept in the app's memory on the Android side, where both engines (the
/// app's and the autofill screen's) can reach it, and nowhere else: written
/// down, it would say a decoy exists.
class VaultSession {
  static const _channel = MethodChannel('ringer_vault/session');

  /// For tests, which have no Android side: what [fingerprintAllowed] says.
  @visibleForTesting
  static bool? debugFingerprintAllowed;

  /// The vault locked. Drops a login kept for the second page of a sign-in
  /// (NextStep.kt), so locking, a panic shake included, leaves nothing
  /// ready to fill.
  static Future<void> locked() async {
    try {
      await _channel.invokeMethod('locked');
    } catch (_) {
      // Not on Android, or no platform side at all (a plain test): nothing
      // kept, and locking must never fail for want of saying so.
    }
  }

  static Future<void> unlocked({required bool decoy, required bool byPin}) async {
    if (debugFingerprintAllowed != null) {
      if (decoy) {
        debugFingerprintAllowed = false;
      } else if (byPin) {
        debugFingerprintAllowed = true;
      }
      return;
    }
    try {
      await _channel.invokeMethod('unlocked', {'decoy': decoy, 'byPin': byPin});
    } on MissingPluginException {
      // Not on Android: nothing to tell.
    } on PlatformException {
      // Nothing to tell either.
    }
  }

  /// For tests: what [lowMemory] says.
  @visibleForTesting
  static bool? debugLowMemory;

  static bool? _lowMemory;

  /// Whether this phone is short enough of memory that the two unlock key
  /// derivations should run one after the other rather than side by side.
  /// Asked once per run.
  static Future<bool> lowMemory() async {
    final forced = debugLowMemory;
    if (forced != null) return forced;
    if (_lowMemory case final known?) return known;
    try {
      return _lowMemory = await _channel.invokeMethod<bool>('lowMemory') ?? false;
    } on MissingPluginException {
      return _lowMemory = false;
    } on PlatformException {
      return _lowMemory = false;
    }
  }

  /// False when unsure: the PIN always works.
  static Future<bool> fingerprintAllowed() async {
    final forced = debugFingerprintAllowed;
    if (forced != null) return forced;
    try {
      return await _channel.invokeMethod<bool>('fingerprintAllowed') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
