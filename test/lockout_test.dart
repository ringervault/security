import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/lockout_clock.dart';
import 'package:ringer_vault/services/vault_key_service.dart';

import 'support/render_harness.dart';

/// Wrong-attempt lockouts, waited out the way someone holding the phone
/// would: only a correct unlock clears the count, so the longer lockouts and
/// self-destruct are reached however the guesses are paced, and the phone's
/// own clock cannot end a lockout early.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  late RenderHarness harness;

  // A clock the test moves: the wall clock, time since boot, and the boot.
  var wall = DateTime.utc(2026, 10, 13, 9);
  var elapsedMs = 1000000;
  int? boot = 7;
  void wait(Duration d) {
    wall = wall.add(d);
    elapsedMs += d.inMilliseconds;
  }

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [
      VaultEntry(id: '1', title: 'Bank', username: 'ada', password: 'pw', category: 'Banking'),
    ]);
    wall = DateTime.utc(2026, 10, 13, 9);
    elapsedMs = 1000000;
    boot = 7;
    LockoutClock.debugNow = () => LockoutTime(wall, elapsedMs: elapsedMs, boot: boot);
    await AuthService().logout();
  });
  tearDown(() async {
    LockoutClock.debugNow = null;
    await harness.tearDown();
  });

  /// One wrong PIN. True when it started a lockout.
  Future<bool> wrong() async {
    try {
      await AuthService().verifyPin('000000');
      return false;
    } on AuthLockoutException {
      return true;
    }
  }

  /// Wrong PINs, each lockout waited out in full, until [n] have counted.
  Future<void> paced(int n) async {
    while (await AuthService().failedAttempts() < n) {
      if (await wrong()) {
        final end = await AuthService().getLockoutTime();
        if (end != null) wait(end.difference(wall) + const Duration(seconds: 1));
      }
    }
  }

  test('the schedule: none, then 30 seconds, 5, 15 and 60 minutes', () {
    expect(AuthService.lockoutAfter(4), isNull);
    expect(AuthService.lockoutAfter(5), const Duration(seconds: 30));
    expect(AuthService.lockoutAfter(10), const Duration(minutes: 5));
    expect(AuthService.lockoutAfter(15), const Duration(minutes: 15));
    expect(AuthService.lockoutAfter(20), const Duration(hours: 1));
  });

  test('waiting out a lockout keeps the count', () async {
    await paced(5);
    expect(await AuthService().getLockoutTime(), isNull, reason: 'waited out');
    expect(await AuthService().failedAttempts(), 5);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('paced guesses still reach the 5-minute lockout', () async {
    await paced(9);
    expect(await wrong(), isTrue);
    final end = await AuthService().getLockoutTime();
    expect(end!.difference(wall), const Duration(minutes: 5));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('paced guesses still reach self-destruct', () async {
    await AuthService().setSelfDestruct(enabled: true, threshold: 15);
    await paced(14);
    expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isTrue);
    await expectLater(AuthService().verifyPin('000000'), throwsA(isA<VaultDestroyedException>()));
    expect(await VaultKeyService().hasPinEnvelope(isDecoy: false), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('only a correct unlock clears the count', () async {
    await paced(6);
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(await AuthService().failedAttempts(), 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('moving the phone\'s clock forward does not end a lockout', () async {
    await paced(4);
    expect(await wrong(), isTrue);
    wall = wall.add(const Duration(days: 1));
    await expectLater(AuthService().verifyPin(pin), throwsA(isA<AuthLockoutException>()));
    elapsedMs += 31000;
    expect(await AuthService().verifyPin(pin), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a restart runs the lockout again in full', () async {
    await paced(4);
    expect(await wrong(), isTrue);
    boot = 8;
    elapsedMs = 5000;
    final end = await AuthService().getLockoutTime();
    expect(end!.difference(wall), const Duration(seconds: 30));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('without the time since boot, the wall clock times it', () async {
    LockoutClock.debugNow = () => LockoutTime(wall);
    await paced(4);
    expect(await wrong(), isTrue);
    await expectLater(AuthService().verifyPin(pin), throwsA(isA<AuthLockoutException>()));
    wall = wall.add(const Duration(seconds: 31));
    expect(await AuthService().verifyPin(pin), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
