import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/auth_service.dart';

import 'support/render_harness.dart';

/// What the app tells Android when a vault opens or locks, which decides
/// whether a login kept for the next page of a sign-in survives
/// (NextStep.kt, VaultSession.kt).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ringer_vault/session');
  const pin = '482916';
  const decoyPin = '246801';
  late RenderHarness harness;
  late List<String> calls;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'unlocked') {
        calls.add('unlocked ${call.arguments['decoy'] == true ? 'decoy' : 'real'}');
      } else if (call.method == 'locked') {
        calls.add('locked');
      } else if (call.method == 'lowMemory') {
        return false;
      } else if (call.method == 'fingerprintAllowed') {
        return false;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await harness.tearDown();
  });

  test('locking an open vault tells Android, once', () async {
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
    calls.clear();
    // A panic shake, leaving the app with auto-lock on, the timer and
    // Strict Offline all lock by logging out.
    await AuthService().logout();
    expect(calls, ['locked']);
  });

  test('tidying up a vault already locked does not', () async {
    await AuthService().logout();
    calls.clear();
    // As the autofill screen does after every fill: the login it has just
    // kept for the next page must survive this.
    await AuthService().logout();
    await AuthService().logout();
    expect(calls, isEmpty);
  });

  test('opening the decoy says so, which drops anything kept', () async {
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
    calls.clear();
    expect(await AuthService().verifyPin(decoyPin), isTrue);
    expect(calls, contains('unlocked decoy'));
  });
}
