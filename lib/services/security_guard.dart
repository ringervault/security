import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/connectivity_service.dart';

/// Blocks vault access while Strict Offline Mode is on and the device is
/// online.
///
/// (The former `SecurityGuard` class lived here too. It was unreferenced, and
/// its `verify()` returned false on every path because all six actions set
/// `requiresReAuth` and both branches fell through to `return false`. Re-auth
/// is handled at the call sites via `verifyPinForReAuth` /
/// `authenticateForReAuth`, which is where the BuildContext for a PIN prompt
/// actually exists.)
class OfflineGuard {
  static void ensureOffline() {
    if (ConnectivityService.instance.isOnline &&
        AuthService().isStrictOfflineModeCached) {
      throw OfflineViolationException('Action blocked by Strict Offline Mode');
    }
  }
}

class OfflineViolationException implements Exception {
  final String message;
  OfflineViolationException(this.message);

  @override
  String toString() => 'OfflineViolationException: $message';
}
