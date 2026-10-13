import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/auth_service.dart';

import 'support/render_harness.dart';

/// Every autofill now asks for the PIN or fingerprint. Someone used to the
/// old three-minute window is told once; nobody else is.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RenderHarness harness;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp();
  });

  tearDown(() => harness.tearDown());

  test('someone who had the three-minute window is told once', () async {
    harness.secureStorage.remove('autofill_gate_notice');
    harness.secureStorage.remove('autofill_unlock_every_time');
    expect(await AuthService().takeAutofillGateNotice(), isTrue);
    expect(await AuthService().takeAutofillGateNotice(), isFalse);
  });

  test('someone who had chosen to be asked every time is not told', () async {
    harness.secureStorage.remove('autofill_gate_notice');
    harness.secureStorage['autofill_unlock_every_time'] = 'true';
    expect(await AuthService().takeAutofillGateNotice(), isFalse);
    expect(harness.secureStorage.containsKey('autofill_unlock_every_time'), isFalse,
        reason: 'the old setting is gone');
  });

  test('a vault set up now is not told', () async {
    harness.secureStorage.remove('autofill_gate_notice');
    await AuthService().completeSetup();
    expect(await AuthService().takeAutofillGateNotice(), isFalse);
  });
}
