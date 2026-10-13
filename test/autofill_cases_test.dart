import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/registrable_domain.dart';

/// The cases in test/fixtures/autofill_cases.json, which the browser
/// extension's tests also run. If this file and extension/test/cases.test.mjs
/// both pass, the app and the extension draw every site boundary the same way.
void main() {
  final cases = jsonDecode(
    File('test/fixtures/autofill_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('where one site ends and another begins', () {
    for (final raw in cases['hosts'] as List) {
      final c = raw as Map<String, dynamic>;
      test(c['host'], () {
        final result = registrableDomain(c['host'] as String);
        if (c['rejection'] != null) {
          expect(result.isUsable, isFalse);
          expect(result.rejection!.name, c['rejection']);
        } else {
          expect(result.registrable, c['registrable']);
          if (c['normalised'] != null) expect(result.host, c['normalised']);
        }
      });
    }
  });

  group('how a page relates to what an entry was saved for', () {
    for (final raw in cases['tiers'] as List) {
      final c = raw as Map<String, dynamic>;
      test(c['why'], () {
        final tier = siteTier(
          savedHosts: List<String>.from(c['saved'] as List),
          pageHost: c['page'] as String,
          scheme: c['scheme'] as String?,
        );
        expect(tier.name, c['tier']);
      });
    }
  });
}
