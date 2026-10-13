import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/auth_service.dart';

/// Google's sign-in and permission screens are other apps, so the app is in
/// the background while they show. Auto-lock must not fire then, or signing
/// in to sync locks the vault halfway through.
void main() {
  test('auto-lock waits until every hold has finished', () async {
    final auth = AuthService();
    expect(auth.autoLockAllowed, isTrue);

    final first = Completer<void>();
    final second = Completer<void>();
    final a = auth.holdAutoLock(() => first.future);
    final b = auth.holdAutoLock(() => second.future);
    expect(auth.autoLockAllowed, isFalse);

    first.complete();
    await a;
    expect(
      auth.autoLockAllowed,
      isFalse,
      reason: 'the other hold is still running',
    );

    second.complete();
    await b;
    expect(auth.autoLockAllowed, isTrue);
  });

  test('a hold that fails still lets auto-lock come back', () async {
    final auth = AuthService();
    await expectLater(
      auth.holdAutoLock<void>(() async => throw StateError('sign-in failed')),
      throwsStateError,
    );
    expect(auth.autoLockAllowed, isTrue);
  });
}
