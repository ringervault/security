import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/sync/sync_merge.dart';

void main() {
  final now = DateTime(2026, 10, 8, 12);
  Map<String, dynamic> logged(int daysAgo, {bool warning = false}) => {
        'timestamp': now.subtract(Duration(days: daysAgo)).toIso8601String(),
        'action': warning ? 'Autofill despite warning' : 'Autofill',
        if (warning) 'isWarning': true,
      };

  test('ordinary activity goes after 15 days', () {
    expect(isExpired(logged(14), now), isFalse);
    expect(isExpired(logged(16), now), isTrue);
  });

  test('anything done despite a warning is kept for 180 days', () {
    expect(isExpired(logged(16, warning: true), now), isFalse,
        reason: 'fraud usually comes to light weeks later');
    expect(isExpired(logged(179, warning: true), now), isFalse);
    expect(isExpired(logged(181, warning: true), now), isTrue);
  });

  test('the long period is the same one the sync keeps deletions for', () {
    expect(warningLogLifetime, tombstoneLifetime);
  });

  test('an entry without a readable time is left alone', () {
    expect(isExpired({'action': 'Autofill'}, now), isFalse);
  });
}
