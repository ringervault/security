import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/sync/sync_engine.dart';

/// The rollback rules, against the cases the extension's tests run too.
void main() {
  final fixture = jsonDecode(File('test/fixtures/rollback_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('generation: ${c['why']}', () {
      expect(
        generationStep(
          found: c['found'] as int,
          seen: c['seen'] as int,
          acceptOlder: c['acceptOlder'] as bool,
        ),
        c['refuse'] == true ? isNull : c['next'],
      );
    });
  }
}
