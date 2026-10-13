import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/autofill_session.dart';

/// The autofill session is a deliberate weakening of "locking ends the
/// session": it keeps the master key in memory between fills so that using a
/// password does not mean retyping the master secret at every login screen.
/// What keeps it defensible is that the window is short, it cannot be
/// extended silently, and the decoy vault never gets one.
void main() {
  test('there is no session before an unlock', () {
    expect(AutofillSession.instance.isLive, isFalse);
    expect(AutofillSession.instance.expiresAt, isNull);
  });

  test('the window is short enough to be defensible', () {
    // A long window here would quietly undo the lock-on-background rule the
    // rest of the app is built on.
    expect(AutofillSession.window, lessThanOrEqualTo(const Duration(minutes: 5)));
    expect(AutofillSession.window, greaterThan(Duration.zero));
  });

  test('beginning a session sets an expiry that is not open-ended', () {
    AutofillSession.instance.begin();
    final at = AutofillSession.instance.expiresAt;

    expect(at, isNotNull);
    expect(at!.isAfter(DateTime.now()), isTrue);
    expect(
      at.difference(DateTime.now()),
      lessThanOrEqualTo(AutofillSession.window),
    );
  });

  test('a session that has run out is not live', () async {
    AutofillSession.instance.begin();
    await AutofillSession.instance.end();

    expect(AutofillSession.instance.isLive, isFalse);
    expect(AutofillSession.instance.expiresAt, isNull);
  });

  test('an unauthenticated engine has no session, whatever the clock says',
      () {
    // isLive asks AuthService as well as the clock, so a session cannot
    // outlive the logout that cleared the key.
    AutofillSession.instance.begin();
    expect(AutofillSession.instance.isLive, isFalse,
        reason: 'nothing is authenticated in a bare test engine');
  });
}
