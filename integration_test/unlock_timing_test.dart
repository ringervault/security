import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/vault_session.dart';

import '../test/support/render_harness.dart';

/// How long an unlock takes, on a real phone, for each kind of PIN: the
/// real one, the decoy's, a wrong one, and a wrong one with no decoy set up.
/// None may stand out: the time a PIN takes must not say which it was, or
/// whether there is a decoy at all.
///
/// Run on a device with:
///   flutter test integration_test/unlock_timing_test.dart -d DEVICE_ID
///
/// Secure storage, preferences and the files folder are the test harness's
/// stand-ins (in memory and a temporary folder), so this never touches the
/// vault the app on that phone holds. The key derivations, the vault file
/// and the encryption run for real on the phone's own CPU.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  const decoyPin = '246801';
  const rounds = 9;

  /// One timed attempt with [candidate], starting as a first wrong one
  /// would: no failures counted, so the lockout after five never comes in.
  Future<Duration> attempt(RenderHarness harness, String candidate, {required bool opens}) async {
    await AuthService().logout();
    harness.secureStorage
      ..remove('failed_attempts')
      ..remove('lockout_time');
    final clock = Stopwatch()..start();
    final ok = await AuthService().verifyPin(candidate);
    clock.stop();
    expect(ok, opens, reason: candidate);
    return clock.elapsed;
  }

  Duration median(List<Duration> times) => (List.of(times)..sort())[times.length ~/ 2];

  testWidgets('every kind of PIN takes the same time', (tester) async {
    // Which way this phone runs the two derivations. On a low-memory phone
    // (or emulator), pass --dart-define=EXPECT_LOW_MEMORY=true to check the
    // one-after-the-other path is the one being measured.
    final lowMemory = await VaultSession.lowMemory();
    // ignore: avoid_print
    print('UNLOCK derivations: ${lowMemory ? 'one after the other (low memory)' : 'side by side'}');
    if (const bool.fromEnvironment('EXPECT_LOW_MEMORY')) {
      expect(lowMemory, isTrue, reason: 'this device was expected to report low memory');
    }

    // Every case in every round, in a shuffled order, with the decoy added
    // and taken away again each round: a phone warming up and slowing down
    // over the run then lands on every case alike, rather than on whichever
    // was measured last.
    final times = <String, List<Duration>>{};
    final random = Random(7);
    await tester.runAsync(() async {
      final harness = RenderHarness();
      await harness.setUp(pin: pin, entries: [
        for (var i = 0; i < 40; i++)
          VaultEntry(id: 'e$i', title: 'Entry $i', username: 'user$i', password: 'pw$i', category: 'Banking'),
      ]);
      // Warm up, unmeasured.
      await attempt(harness, pin, opens: true);
      await attempt(harness, '999999', opens: false);

      for (var round = 0; round < rounds; round++) {
        for (final withDecoy in ([false, true]..shuffle(random))) {
          await AuthService().logout();
          expect(await AuthService().verifyPin(pin), isTrue);
          // The same setup either way, one key derivation included, so
          // neither kind of round starts warmer than the other.
          await AuthService().setSecondaryPin(withDecoy ? '' : decoyPin);
          await AuthService().setSecondaryPin(withDecoy ? decoyPin : '');
          final cases = <(String, String, bool)>[
            ('wrong PIN, ${withDecoy ? 'decoy' : 'no decoy'}', '999999', false),
            ('real PIN, ${withDecoy ? 'decoy' : 'no decoy'}', pin, true),
            if (withDecoy) ('decoy PIN', decoyPin, true),
          ]..shuffle(random);
          for (final (what, candidate, opens) in cases) {
            (times[what] ??= []).add(await attempt(harness, candidate, opens: opens));
          }
        }
      }
      await harness.tearDown();
    });

    final results = {for (final e in times.entries) e.key: median(e.value)};
    // ignore: avoid_print
    results.forEach((what, t) => print('UNLOCK $what: ${t.inMilliseconds} ms (median of ${times[what]!.length})'));

    // Wrong PINs also pause for the failure counter, which a right one does
    // not; what must match is each against its own kind, and every right PIN
    // against every other.
    void close(String a, String b) {
      final x = results[a]!.inMicroseconds, y = results[b]!.inMicroseconds;
      final spread = (x - y).abs() / (x < y ? x : y);
      expect(spread, lessThan(0.15), reason: '$a ${x ~/ 1000} ms against $b ${y ~/ 1000} ms');
    }

    close('wrong PIN, no decoy', 'wrong PIN, decoy');
    close('real PIN, no decoy', 'real PIN, decoy');
    close('real PIN, decoy', 'decoy PIN');
  });
}
