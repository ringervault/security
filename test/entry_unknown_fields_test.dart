import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';

import 'support/render_harness.dart';

/// Forward compatibility: a field this version does not know, written by a
/// newer app or extension, survives this version reading, changing and
/// writing the entry, so adding an optional field never needs a migration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> record() => {
        'id': 'amazon',
        'title': 'Amazon',
        'username': 'ada',
        'password': 'new',
        'category': 'Social',
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-10-01T00:00:00.000',
        // From the future.
        'shareGrants': [
          {'with': 'family', 'grantedAt': '2026-09-01T00:00:00.000Z'},
        ],
        'passkeyIds': ['k1'],
      };

  test('an unknown field is kept, untouched, through a read and a write', () {
    final json = VaultEntry.fromJson(record()).toJson();
    expect(json['shareGrants'], record()['shareGrants']);
    expect(json['passkeyIds'], ['k1']);
  });

  test('and through an edit', () {
    final edited = VaultEntry.fromJson(record()).copyWith(password: 'newer');
    expect(edited.toJson()['shareGrants'], record()['shareGrants']);
    expect(edited.password, 'newer');
  });

  test('a known field is never taken from the unknown ones', () {
    final entry = VaultEntry.fromJson(record());
    expect(entry.extra.keys, unorderedEquals(['shareGrants', 'passkeyIds']));
    expect(entry.toJson()['password'], 'new');
  });

  group('in the vault file', () {
    late RenderHarness harness;
    setUp(() async {
      harness = RenderHarness();
      await harness.setUp(pin: '482916');
    });
    tearDown(() => harness.tearDown());

    test('kept through saving, locking and opening again', () async {
      await StorageService().addEntry(VaultEntry.fromJson(record()));
      await StorageService().updateEntry(
          StorageService().getEntries().single.copyWith(title: 'Amazon India'));
      await AuthService().logout();
      expect(await AuthService().verifyPin('482916'), isTrue);
      final json = StorageService().getEntries().single.toJson();
      expect(json['title'], 'Amazon India');
      expect(json['shareGrants'], record()['shareGrants']);
    });
  });
}
