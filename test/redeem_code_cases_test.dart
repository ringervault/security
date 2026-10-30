import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/subscription/redeem_code.dart';

/// The redeem codes in test/fixtures/code_cases.json, which the extension's
/// tests (extension/test/codes.test.mjs) also run: both sides read every
/// code, and count every set of redeemed codes, the same way.
void main() {
  final cases = jsonDecode(File('test/fixtures/code_cases.json').readAsStringSync()) as Map;
  final testKey = cases['publicKey'] as String;
  String codeFor(String why) =>
      (cases['codes'] as List).firstWhere((c) => c['why'] == why)['code'] as String;

  group('the shared cases', () {
    for (final c in (cases['codes'] as List).cast<Map>()) {
      test('code: ${c['why']}', () async {
        final code = RedeemCode.parse(c['code'] as String);
        final genuine = code != null && await code.isGenuine(publicKey: testKey);
        expect(genuine, c['genuine']);
        if (c['genuine'] == true) {
          expect(code!.id, c['id']);
          expect(code.kind.index + 1, c['kind']);
          expect(code.amount, c['amount']);
          expect(code.redeemBy.subtract(const Duration(seconds: 1)).toIso8601String().substring(0, 10),
              c['redeemBy']);
        }
      });
    }

    for (final c in (cases['grants'] as List).cast<Map>()) {
      test('grants: ${c['why']}', () async {
        final grants = [for (final g in c['grants'] as List) ?CodeGrant.fromJson(g)];
        final until = grantsUntil(await countedGrants(grants, publicKey: testKey));
        expect(until?.toIso8601String(), c['until'] == null ? null : DateTime.parse(c['until'] as String).toIso8601String());
      });
    }

    test('the real key does not accept codes made with the test key', () async {
      expect(RedeemCode.codePublicKey, isNot(testKey));
      expect(await RedeemCode.parse(codeFor('one week'))!.isGenuine(), isFalse);
    });

    test('a code says what it gives', () {
      expect(RedeemCode.parse(codeFor('one day'))!.describe, '1 day');
      expect(RedeemCode.parse(codeFor('one week'))!.describe, '1 week');
      expect(RedeemCode.parse(codeFor('one month'))!.describe, '1 month');
      expect(RedeemCode.parse(codeFor('one year'))!.describe, '1 year');
      expect(RedeemCode.parse(codeFor('lifetime'))!.describe, 'Lifetime');
    });
  });
}
