import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/sync/sync_merge.dart';

/// Merging is where sync can lose a password, or bring back one the user
/// deleted after a breach. These tests go after both, and after the property
/// that makes sync trustworthy at all: two devices that exchange copies end
/// up holding the same vault.
void main() {
  final t0 = DateTime.utc(2026, 9, 1, 12);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  SyncRecord live(String id, int minute, {String password = 'pw'}) =>
      SyncRecord(
        id: id,
        updatedAt: at(minute),
        entry: {'id': id, 'title': id, 'password': password},
      );

  SyncRecord gone(String id, int minute) =>
      SyncRecord.deleted(id: id, updatedAt: at(minute));

  Map<String, SyncRecord> vault(List<SyncRecord> records) =>
      {for (final r in records) r.id: r};

  group('one side has something the other does not', () {
    test('a new local entry is kept and sent up', () {
      final result = merge(local: vault([live('a', 0)]), remote: {});

      expect(result.merged['a'], live('a', 0));
      expect(result.localChanged, isFalse);
      expect(result.remoteChanged, isTrue);
    });

    test('a new remote entry is brought down', () {
      final result = merge(local: {}, remote: vault([live('a', 0)]));

      expect(result.upsertLocally, {'a'});
      expect(result.remoteChanged, isFalse);
    });

    test('a remote deletion of something never seen here changes nothing here',
        () {
      final result = merge(local: {}, remote: vault([gone('a', 0)]));

      expect(result.deleteLocally, isEmpty);
      expect(result.upsertLocally, isEmpty);
      expect(result.merged['a']!.isDeleted, isTrue,
          reason: 'the deletion is still remembered for other devices');
    });
  });

  group('both sides changed the same entry', () {
    test('the later edit wins, whichever side it is on', () {
      final older = live('a', 0, password: 'old');
      final newer = live('a', 5, password: 'new');

      final pulled = merge(local: vault([older]), remote: vault([newer]));
      expect(pulled.merged['a'], newer);
      expect(pulled.upsertLocally, {'a'});
      expect(pulled.remoteChanged, isFalse);

      final pushed = merge(local: vault([newer]), remote: vault([older]));
      expect(pushed.merged['a'], newer);
      expect(pushed.localChanged, isFalse);
      expect(pushed.remoteChanged, isTrue);
    });

    test('an identical copy on both sides changes nothing anywhere', () {
      final result = merge(
        local: vault([live('a', 0)]),
        remote: vault([live('a', 0)]),
      );
      expect(result.localChanged, isFalse);
      expect(result.remoteChanged, isFalse);
    });
  });

  group('deletions', () {
    test('a deletion newer than the other copy is not undone', () {
      // Deleted on the phone after a breach; the browser still has the old
      // copy. Syncing must not put it back.
      final result = merge(
        local: vault([live('a', 0)]),
        remote: vault([gone('a', 5)]),
      );

      expect(result.merged['a']!.isDeleted, isTrue);
      expect(result.deleteLocally, {'a'});
      expect(result.upsertLocally, isEmpty);
    });

    test('a local deletion is sent up rather than overwritten', () {
      final result = merge(
        local: vault([gone('a', 5)]),
        remote: vault([live('a', 0)]),
      );

      expect(result.merged['a']!.isDeleted, isTrue);
      expect(result.upsertLocally, isEmpty,
          reason: 'the stale remote copy must not come back');
      expect(result.remoteChanged, isTrue);
    });

    test('an edit made after the deletion brings the entry back', () {
      // This is last-writer-wins doing what it says: someone changed the
      // entry after it was deleted elsewhere, so the change is the newer
      // intent. Written down so it is a decision, not a surprise.
      final result = merge(
        local: vault([gone('a', 0)]),
        remote: vault([live('a', 5, password: 'edited later')]),
      );

      expect(result.merged['a']!.isDeleted, isFalse);
      expect(result.upsertLocally, {'a'});
    });
  });

  group('exact ties', () {
    test('a deletion beats an edit in the same instant', () {
      final result = merge(
        local: vault([live('a', 3)]),
        remote: vault([gone('a', 3)]),
      );
      expect(result.merged['a']!.isDeleted, isTrue);
    });

    test('two different edits in the same instant pick the same winner '
        'whichever side does the merging', () {
      final x = live('a', 3, password: 'x');
      final y = live('a', 3, password: 'y');

      final fromX = merge(local: vault([x]), remote: vault([y]));
      final fromY = merge(local: vault([y]), remote: vault([x]));

      expect(fromX.merged['a'], fromY.merged['a']);
    });
  });

  group('properties', () {
    test('merging is symmetric', () {
      final a = vault([live('1', 1), gone('2', 4), live('3', 2, password: 'p')]);
      final b = vault([live('1', 3), live('2', 2), live('4', 0)]);

      expect(merge(local: a, remote: b).merged,
          merge(local: b, remote: a).merged);
    });

    test('merging a result with itself changes nothing', () {
      final a = vault([live('1', 1), gone('2', 4)]);
      final b = vault([live('1', 3), live('2', 2)]);

      final once = merge(local: a, remote: b).merged;
      final twice = merge(local: once, remote: once);

      expect(twice.localChanged, isFalse);
      expect(twice.remoteChanged, isFalse);
    });

    test('two devices with random histories converge on the same vault', () {
      // Two devices, each making a random run of edits and deletions to an
      // overlapping set of entries, then syncing through one remote copy in
      // turn. Afterwards they must hold exactly the same thing. Seeded, so a
      // failure is reproducible.
      for (var seed = 0; seed < 200; seed++) {
        final rng = Random(seed);
        Map<String, SyncRecord> randomDevice() {
          final records = <String, SyncRecord>{};
          for (var i = 0; i < 12; i++) {
            final id = 'e${rng.nextInt(8)}';
            final minute = rng.nextInt(20);
            records[id] = rng.nextInt(4) == 0
                ? gone(id, minute)
                : live(id, minute, password: 'p${rng.nextInt(3)}');
          }
          return records;
        }

        final phone = randomDevice();
        final browser = randomDevice();

        // Phone syncs first against an empty remote, then the browser, then
        // the phone again to pick up what the browser added.
        var remote = merge(local: phone, remote: {}).merged;
        final browserAfter = merge(local: browser, remote: remote).merged;
        remote = browserAfter;
        final phoneAfter = merge(local: phone, remote: remote).merged;

        expect(phoneAfter, browserAfter, reason: 'diverged at seed $seed');
      }
    });
  });

  group('forgetting old deletions', () {
    test('a deletion inside the window is kept', () {
      final pruned = pruneTombstones(
        vault([gone('a', 0)]),
        now: at(0).add(const Duration(days: 30)),
      );
      expect(pruned.containsKey('a'), isTrue);
    });

    test('a deletion past the window is dropped', () {
      final pruned = pruneTombstones(
        vault([gone('a', 0)]),
        now: at(0).add(tombstoneLifetime + const Duration(days: 1)),
      );
      expect(pruned.containsKey('a'), isFalse);
    });

    test('live entries are never pruned, however old', () {
      final pruned = pruneTombstones(
        vault([live('a', 0)]),
        now: at(0).add(const Duration(days: 5000)),
      );
      expect(pruned.containsKey('a'), isTrue);
    });
  });

  group('reading records from a file', () {
    test('a record round-trips', () {
      final original = live('a', 7, password: 'with "quotes" and ünïcode');
      expect(SyncRecord.tryParse(original.toJson()), original);

      final deletion = gone('b', 9);
      expect(SyncRecord.tryParse(deletion.toJson()), deletion);
    });

    test('malformed records are skipped rather than trusted', () {
      for (final bad in <Object?>[
        null,
        'a string',
        <String, dynamic>{},
        {'id': 'a'},
        {'id': '', 'updatedAt': '2026-01-01T00:00:00Z', 'entry': {}},
        {'id': 'a', 'updatedAt': 'not a date', 'entry': {}},
        {'id': 'a', 'updatedAt': '2026-01-01T00:00:00Z'},
        {'id': 'a', 'updatedAt': '2026-01-01T00:00:00Z', 'entry': 'x'},
      ]) {
        expect(SyncRecord.tryParse(bad), isNull, reason: 'accepted: $bad');
      }
    });
  });
}
