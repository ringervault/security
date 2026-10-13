import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_engine.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_payload.dart';
import 'package:ringer_vault/sync/sync_transport.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

/// Sync as a whole, with two simulated devices sharing one remote copy.
///
/// The remote is a fake so that the failures that matter can be produced on
/// demand: another device writing between our read and our write, a server
/// that ignores conditional writes, a file from a newer app, a passphrase
/// that does not match. Each of those, handled wrongly, loses a password.
void main() {
  const passphrase = 'a long enough sync passphrase';

  var now = DateTime.utc(2026, 9, 1, 12);
  DateTime tick([int minutes = 1]) => now = now.add(Duration(minutes: minutes));

  setUp(() => now = DateTime.utc(2026, 9, 1, 12));

  SyncEngine device(
    MemoryVault vault,
    FakeTransport remote, {
    String id = 'device',
    bool strictOffline = false,
    bool decoy = false,
    String key = passphrase,
    int maxAttempts = 3,
    SyncCipher? cipher,
    MemoryMarks? marks,
  }) =>
      SyncEngine(
        transport: remote,
        vault: vault,
        cipher: cipher ?? SyncCipher(key),
        deviceId: id,
        isStrictOffline: () => strictOffline,
        isDecoy: () => decoy,
        marks: marks,
        clock: () => now,
        maxAttempts: maxAttempts,
      );

  group('the ordinary path', () {
    test('the first device creates the remote copy', () async {
      final phone = MemoryVault()..edit('a', 'pw-a', now);
      final remote = FakeTransport();

      final outcome = await device(phone, remote).run();

      expect(outcome.pushed, isTrue);
      expect(remote.content, isNotNull);
      expect(remote.content, isNot(contains('pw-a')),
          reason: 'what reaches Google must be ciphertext');
    });

    test('a second device receives what the first one had', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw-a', now);
      await device(phone, remote, id: 'phone').run();

      final browser = MemoryVault();
      final outcome = await device(browser, remote, id: 'browser').run();

      expect(outcome.pulled, 1);
      expect(outcome.pushed, isFalse, reason: 'nothing new to send back');
      expect(browser.passwordOf('a'), 'pw-a');
    });

    test('edits to different entries on two devices both survive', () async {
      final remote = FakeTransport();
      final phone = MemoryVault();
      final browser = MemoryVault();

      phone.edit('bank', 'from-phone', tick());
      browser.edit('email', 'from-browser', tick());

      await device(phone, remote, id: 'phone').run();
      await device(browser, remote, id: 'browser').run();
      await device(phone, remote, id: 'phone').run();

      for (final v in [phone, browser]) {
        expect(v.passwordOf('bank'), 'from-phone');
        expect(v.passwordOf('email'), 'from-browser');
      }
    });

    test('a sync with nothing new writes nothing', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote).run();

      final writes = remote.writes;
      final outcome = await device(phone, remote).run();

      expect(outcome.pushed, isFalse);
      expect(remote.writes, writes);
    });
  });

  group('deletions', () {
    test('a password deleted on one device is removed on the other', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('old', 'breached', now);
      await device(phone, remote, id: 'phone').run();

      final browser = MemoryVault();
      await device(browser, remote, id: 'browser').run();
      expect(browser.passwordOf('old'), 'breached');

      phone.delete('old', tick());
      await device(phone, remote, id: 'phone').run();
      final outcome = await device(browser, remote, id: 'browser').run();

      expect(outcome.removed, 1);
      expect(browser.passwordOf('old'), isNull);
    });

    test('a deleted password does not come back from a stale device', () async {
      // The browser was offline when the phone deleted the entry. When it
      // syncs, its old copy must lose, not resurrect the password.
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('old', 'breached', now);
      final browser = MemoryVault()..edit('old', 'breached', now);

      await device(phone, remote, id: 'phone').run();
      phone.delete('old', tick());
      await device(phone, remote, id: 'phone').run();

      await device(browser, remote, id: 'browser').run();
      await device(phone, remote, id: 'phone').run();

      expect(phone.passwordOf('old'), isNull);
      expect(browser.passwordOf('old'), isNull);
    });
  });

  group('refusing to sync', () {
    test('Strict Offline Mode stops sync before any network call', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);

      await expectLater(
        device(phone, remote, strictOffline: true).run(),
        throwsA(isA<SyncBlocked>()),
      );
      expect(remote.reads, 0, reason: 'not even a download');
      expect(remote.writes, 0);
    });

    test('the decoy vault never syncs', () async {
      final remote = FakeTransport();
      final decoy = MemoryVault()..edit('fake', 'decoy-pw', now);

      await expectLater(
        device(decoy, remote, decoy: true).run(),
        throwsA(isA<SyncBlocked>()),
      );
      expect(remote.reads, 0);
      expect(remote.writes, 0);
    });

    test('a passphrase that does not open the remote copy changes nothing',
        () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'real', now);
      await device(phone, remote).run();
      final before = remote.content;

      final other = MemoryVault()..edit('b', 'mine', now);
      await expectLater(
        device(other, remote, key: 'a different passphrase entirely').run(),
        throwsA(isA<SyncPassphraseError>()),
      );

      expect(remote.content, before,
          reason: 'the unreadable copy is another device\'s data');
      expect(other.passwordOf('a'), isNull);
      expect(other.passwordOf('b'), 'mine');
    });

    test('a copy from a newer app is refused, not overwritten', () async {
      final remote = FakeTransport();
      remote.content = await _encryptRaw(
        '{"format":"ringer-vault-sync","version":99,"records":[]}',
        passphrase,
      );
      final before = remote.content;

      final phone = MemoryVault()..edit('a', 'pw', now);
      await expectLater(
        device(phone, remote).run(),
        throwsA(isA<SyncPayloadError>()),
      );
      expect(remote.content, before);
    });
  });

  group('races', () {
    test('another device writing mid-sync is merged in, not overwritten',
        () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('bank', 'from-phone', now);
      final browser = MemoryVault()..edit('email', 'from-browser', tick());

      // The browser syncs in the gap between the phone's read and its write.
      remote.beforeNextUpload = () => device(browser, remote, id: 'browser').run();

      final outcome = await device(phone, remote, id: 'phone').run();
      expect(outcome.attempts, 2, reason: 'the first write must be refused');

      // The browser picks up the phone's entry on its next sync.
      await device(browser, remote, id: 'browser').run();

      for (final v in [phone, browser]) {
        expect(v.passwordOf('bank'), 'from-phone');
        expect(v.passwordOf('email'), 'from-browser');
      }
    });

    test('a server that ignores conditional writes still loses nothing',
        () async {
      // Google Drive does not enforce a conditional update the way this
      // engine would like. The design must survive that: whichever write
      // lands last, the other device still has its own changes locally and
      // puts them back on its next sync.
      final remote = FakeTransport(enforcesVersions: false);
      final phone = MemoryVault()..edit('bank', 'from-phone', now);
      final browser = MemoryVault()..edit('email', 'from-browser', tick());

      remote.beforeNextUpload = () => device(browser, remote, id: 'browser').run();
      await device(phone, remote, id: 'phone').run();
      // The phone's write just clobbered the browser's.

      await device(browser, remote, id: 'browser').run();
      await device(phone, remote, id: 'phone').run();

      for (final v in [phone, browser]) {
        expect(v.passwordOf('bank'), 'from-phone');
        expect(v.passwordOf('email'), 'from-browser');
      }
    });

    test('endless collisions give up cleanly', () async {
      final remote = FakeTransport()..alwaysConflict = true;
      final phone = MemoryVault()..edit('a', 'pw', now);

      await expectLater(
        device(phone, remote, maxAttempts: 3).run(),
        throwsA(isA<SyncGaveUp>()),
      );
      expect(phone.passwordOf('a'), 'pw', reason: 'nothing lost locally');
    });
  });

  group('speed', () {
    test('when nothing changed anywhere, nothing is downloaded', () async {
      // The common case for auto sync: one small request, no download, no
      // key derivation.
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: marks).run();

      final fetches = remote.fetches;
      final writes = remote.writes;
      final outcome = await device(phone, remote, marks: marks).run();

      expect(outcome.upToDate, isTrue);
      expect(remote.fetches, fetches, reason: 'no download');
      expect(remote.writes, writes, reason: 'no upload');
    });

    test('a local edit is noticed even when the remote has not moved',
        () async {
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: marks).run();

      phone.edit('a', 'changed', tick());
      final outcome = await device(phone, remote, marks: marks).run();

      expect(outcome.upToDate, isFalse);
      expect(outcome.pushed, isTrue);
    });

    test('a remote change is noticed even when nothing changed here',
        () async {
      final remote = FakeTransport();
      final phoneMarks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: phoneMarks).run();

      final browser = MemoryVault();
      await device(browser, remote, id: 'browser').run();
      browser.edit('b', 'from-browser', tick());
      await device(browser, remote, id: 'browser').run();

      final outcome = await device(phone, remote, marks: phoneMarks).run();
      expect(outcome.upToDate, isFalse);
      expect(phone.passwordOf('b'), 'from-browser');
    });

    test('the key is derived once and then reused across syncs', () async {
      // Deriving the key is the slow part. After the first read the cipher
      // keeps it, and writes reuse the backup's salt so it stays valid.
      final remote = FakeTransport();
      final cipher = SyncCipher(passphrase);
      final phone = MemoryVault()..edit('a', 'pw', now);

      await device(phone, remote, cipher: cipher).run();
      final firstSalt = remote.content!.substring(0, 20);
      expect(cipher.isWarm, isTrue);

      phone.edit('a', 'changed', tick());
      await device(phone, remote, cipher: cipher).run();
      expect(remote.content!.substring(0, 20), firstSalt,
          reason: 'same salt, so every device keeps its derived key');
    });

    test('a device joining later adopts the existing salt', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote).run();
      final salt = remote.content!.substring(0, 20);

      final browser = MemoryVault()..edit('b', 'new', tick());
      await device(browser, remote, id: 'browser').run();

      expect(remote.content!.substring(0, 20), salt);
    });
  });

  group('progress', () {
    test('goes from start to 100% and never backwards', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote).run();

      final browser = MemoryVault()..edit('b', 'x', tick());
      final seen = <double>[];
      final stages = <String>{};
      await device(browser, remote, id: 'browser').run(
        onProgress: (fraction, stage) {
          seen.add(fraction);
          stages.add(stage);
        },
      );

      expect(seen.last, 1.0);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]),
            reason: 'went backwards at step $i: $seen');
      }
      expect(stages, contains('Downloading backup'));
      expect(stages, contains('Merging'));
    });

    test('stays monotonic across a retry', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('bank', 'p', now);
      final browser = MemoryVault()..edit('email', 'b', tick());
      remote.beforeNextUpload =
          () => device(browser, remote, id: 'browser').run();

      final seen = <double>[];
      await device(phone, remote, id: 'phone')
          .run(onProgress: (f, _) => seen.add(f));

      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.last, 1.0);
    });
  });

  group('an older copy put back in Drive', () {
    Future<int> generationIn(FakeTransport remote) async =>
        (await SyncPayload.decrypt(remote.content!, SyncCipher(passphrase))).generation;

    test('every write raises the generation, on every device', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, id: 'phone', marks: MemoryMarks()).run();
      expect(await generationIn(remote), 1);

      phone.edit('a', 'pw2', tick());
      await device(phone, remote, id: 'phone').run();
      expect(await generationIn(remote), 2);

      final browser = MemoryVault()..edit('b', 'pw-b', tick());
      await device(browser, remote, id: 'browser').run();
      expect(await generationIn(remote), 3);
    });

    test('is refused, and nothing changes on either side', () async {
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()
        ..edit('bank', 'old-breached', now)
        ..edit('mail', 'pw-mail', now);
      await device(phone, remote, marks: marks).run();
      final older = remote.content!;

      // After a breach: the bank password changed, the mail login deleted.
      phone.edit('bank', 'new-safe', tick());
      phone.delete('mail', tick());
      await device(phone, remote, marks: marks).run();

      remote.putBack(older);
      final writes = remote.writes;
      await expectLater(
        device(phone, remote, marks: marks).run(),
        throwsA(isA<SyncRolledBack>()
            .having((e) => e.found, 'found', 1)
            .having((e) => e.seen, 'seen', 2)),
      );
      expect(remote.content, older, reason: 'not overwritten either');
      expect(remote.writes, writes);
      expect(phone.passwordOf('bank'), 'new-safe', reason: 'the old password does not come back');
      expect(phone.passwordOf('mail'), isNull, reason: 'the deleted login does not come back');
    });

    test('a copy from before the counter existed counts as the oldest', () async {
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: marks).run();

      remote.putBack(await _encryptRaw(
        '{"format":"ringer-vault-sync","version":1,"records":[]}',
        passphrase,
      ));
      await expectLater(
        device(phone, remote, marks: marks).run(),
        throwsA(isA<SyncRolledBack>()),
      );
    });

    test('taken on purpose, it is merged and becomes the newest copy', () async {
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: marks).run();
      final older = remote.content!;
      phone.edit('b', 'pw-b', tick());
      await device(phone, remote, marks: marks).run();
      phone.edit('c', 'pw-c', tick());
      await device(phone, remote, marks: marks).run();
      expect(marks.mark!.generation, 3);

      remote.putBack(older);
      await device(phone, remote, marks: marks).run(acceptOlder: true);

      expect(await generationIn(remote), 4,
          reason: 'newer than anything any device saw, so none refuses it');
      expect(marks.mark!.generation, 4);
      // Then ordinary syncs carry on.
      phone.edit('d', 'pw-d', tick());
      await device(phone, remote, marks: marks).run();
      expect(await generationIn(remote), 5);
    });

    test('a device syncing for the first time takes whatever is there', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: MemoryMarks()).run();
      phone.edit('a', 'pw2', tick());
      await device(phone, remote).run();

      final browser = MemoryVault();
      await device(browser, remote, marks: MemoryMarks()).run();
      expect(browser.passwordOf('a'), 'pw2');
    });
  });

  group('damaged or hostile data in Drive', () {
    /// A phone that has synced twice, and what it and Drive hold after.
    Future<(MemoryVault, FakeTransport, MemoryMarks)> synced() async {
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()
        ..edit('bank', 'pw-bank', now)
        ..edit('mail', 'pw-mail', now);
      await device(phone, remote, marks: marks).run();
      phone.edit('bank', 'pw-bank-2', tick());
      await device(phone, remote, marks: marks).run();
      return (phone, remote, marks);
    }

    /// Plants [hostile] in Drive and checks that syncing refuses it with
    /// [error], writes nothing there, and changes nothing here.
    Future<void> refuses(String hostile, Matcher error) async {
      final (phone, remote, marks) = await synced();
      remote.putBack(hostile);
      final writes = remote.writes;
      await expectLater(device(phone, remote, marks: marks).run(), throwsA(error));
      expect(remote.content, hostile, reason: 'not overwritten');
      expect(remote.writes, writes);
      expect(phone.passwordOf('bank'), 'pw-bank-2');
      expect(phone.passwordOf('mail'), 'pw-mail');
    }

    Future<String> sealed(String json) => _encryptRaw(json, passphrase);
    String good(int generation, List<Object> records) => jsonEncode({
          'format': 'ringer-vault-sync',
          'version': 2,
          'generation': generation,
          'records': records,
        });
    Map<String, Object> record(String id, String password) => {
          'id': id,
          'updatedAt': '2026-09-02T00:00:00Z',
          'entry': {'id': id, 'title': id, 'password': password},
        };

    test('a truncated file', () async {
      final (_, remote, _) = await synced();
      final whole = remote.content!;
      await refuses(whole.substring(0, whole.length ~/ 2), isA<SyncPassphraseError>());
    });

    test('a changed byte in the ciphertext', () async {
      final (_, remote, _) = await synced();
      final bytes = base64Decode(remote.content!);
      bytes[bytes.length - 3] ^= 0x01;
      await refuses(base64Encode(bytes), isA<SyncPassphraseError>());
    });

    test('changed key settings in the header', () async {
      final (_, remote, _) = await synced();
      final bytes = base64Decode(remote.content!);
      bytes[13] = 2; // two passes instead of three
      await refuses(base64Encode(bytes), isA<SyncPassphraseError>());
    });

    test('something that is not a vault at all', () async {
      await refuses('%%% not base64 %%%', isA<SyncPassphraseError>());
      await refuses('', isA<SyncPassphraseError>());
      await refuses(base64Encode(utf8.encode('{"records": []}')), isA<SyncPassphraseError>());
    });

    test('decrypts, but is not text', () async {
      await refuses(
        await StorageService().encryptData([0xFF, 0xFE, 0x00, 0xC3], passphrase),
        isA<SyncPayloadError>(),
      );
    });

    test('decrypts, but is not a sync file', () async {
      await refuses(await sealed('[1, 2, 3]'), isA<SyncPayloadError>());
      await refuses(await sealed('{"format":"ringer-vault-sync","version":2,"records":{}}'),
          isA<SyncPayloadError>());
      await refuses(
          await sealed('{"format":"ringer-vault-sync","version":2,"generation":"9","records":[]}'),
          isA<SyncPayloadError>());
    });

    test('one damaged record among good ones refuses the whole copy', () async {
      await refuses(
        await sealed(good(9, [
          record('bank', 'from-drive'),
          {'id': 'mail', 'updatedAt': 'yesterday-ish', 'entry': {}},
        ])),
        isA<SyncPayloadError>(),
      );
    });

    test('an entry this device cannot store is refused before anything is written', () async {
      final (phone, remote, marks) = await synced();
      phone.unstorable.add('new');
      remote.putBack(await sealed(good(9, [
        record('bank', 'pw-bank-2'),
        record('mail', 'pw-mail'),
        record('ok', 'would-be-fine'),
        record('new', 'damaged'),
      ])));
      final writes = remote.writes;
      await expectLater(device(phone, remote, marks: marks).run(),
          throwsA(isA<SyncPayloadError>()));
      expect(phone.passwordOf('ok'), isNull, reason: 'not half applied');
      expect(remote.writes, writes);
    });
  });

  group('a backup deleted elsewhere', () {
    test('is not recreated by a device that still has the data', () async {
      // Logging out with "delete backup" on one device must not be undone by
      // the next auto sync on another.
      final remote = FakeTransport();
      final marks = MemoryMarks();
      final phone = MemoryVault()..edit('a', 'pw', now);
      await device(phone, remote, marks: marks).run();

      await remote.delete();
      final writes = remote.writes;

      await expectLater(
        device(phone, remote, marks: marks).run(),
        throwsA(isA<SyncRemoteGone>()),
      );
      expect(remote.content, isNull, reason: 'the deletion stands');
      expect(remote.writes, writes);
      expect(phone.passwordOf('a'), 'pw', reason: 'local data untouched');
    });

    test('a first sync with no backup creates one as normal', () async {
      final remote = FakeTransport();
      final phone = MemoryVault()..edit('a', 'pw', now);

      final outcome =
          await device(phone, remote, marks: MemoryMarks()).run();
      expect(outcome.pushed, isTrue);
      expect(remote.content, isNotNull);
    });
  });
}

/// Encrypts arbitrary JSON in the sync file's outer format, to plant a file
/// the engine did not write.
Future<String> _encryptRaw(String json, String passphrase) =>
    StorageService().encryptData(utf8.encode(json), passphrase);

/// Remembers where the last sync left things, like the app's secure store.
class MemoryMarks implements SyncMarkStore {
  SyncMark? mark;

  @override
  Future<SyncMark?> load() async => mark;

  @override
  Future<void> save(SyncMark m) async => mark = m;
}

/// An in-memory vault that behaves like the real one from sync's side.
class MemoryVault implements SyncVault {
  final Map<String, SyncRecord> _live = {};
  final Map<String, DateTime> _deleted = {};

  /// Ids whose incoming copy this vault cannot store, to stand in for a
  /// damaged entry.
  final Set<String> unstorable = {};

  @override
  bool canStore(SyncRecord record) => !unstorable.contains(record.id);

  void edit(String id, String password, DateTime at) {
    _live[id] = SyncRecord(
      id: id,
      updatedAt: at,
      entry: {'id': id, 'title': id, 'password': password},
    );
    _deleted.remove(id);
  }

  void delete(String id, DateTime at) {
    _live.remove(id);
    _deleted[id] = at;
  }

  String? passwordOf(String id) => _live[id]?.entry?['password'] as String?;

  @override
  Map<String, SyncRecord> snapshot() => {
        ..._live,
        for (final d in _deleted.entries)
          if (!_live.containsKey(d.key))
            d.key: SyncRecord.deleted(id: d.key, updatedAt: d.value),
      };

  @override
  Future<void> applyEntry(SyncRecord record) async {
    _live[record.id] = record;
    _deleted.remove(record.id);
  }

  @override
  Future<void> applyDeletion(SyncRecord record) async {
    _live.remove(record.id);
    _deleted[record.id] = record.updatedAt;
  }

  @override
  Future<void> replaceDeletions(Map<String, DateTime> deletions) async {
    _deleted
      ..clear()
      ..addAll(deletions);
  }
}

/// A remote copy that can be made to misbehave on purpose.
class FakeTransport implements SyncTransport {
  final bool enforcesVersions;
  FakeTransport({this.enforcesVersions = true});

  String? content;
  int _version = 0;
  int reads = 0;
  int writes = 0;
  bool alwaysConflict = false;

  /// Runs once, just before the next upload is checked. Used to put another
  /// device's write into the gap between our read and our write.
  Future<void> Function()? beforeNextUpload;

  int fetches = 0;

  @override
  Future<RemoteInfo?> info() async {
    reads++;
    return content == null ? null : RemoteInfo(version: '$_version');
  }

  @override
  Future<String> fetch(RemoteInfo info, {ByteProgress? onBytes}) async {
    fetches++;
    final c = content;
    if (c == null) throw const SyncTransportError('gone');
    onBytes?.call(c.length ~/ 2, c.length);
    onBytes?.call(c.length, c.length);
    return c;
  }

  @override
  Future<String> upload(String data, {required String? ifVersion}) async {
    final hook = beforeNextUpload;
    if (hook != null) {
      beforeNextUpload = null;
      await hook();
    }
    if (alwaysConflict) throw const SyncConflict();

    if (enforcesVersions) {
      final current = content == null ? null : '$_version';
      if (ifVersion != current) throw const SyncConflict();
    }
    content = data;
    _version++;
    writes++;
    return '$_version';
  }

  @override
  Future<void> delete() async {
    content = null;
    _version++;
  }

  /// What restoring an earlier revision in Drive does: older content, as a
  /// new version of the file.
  void putBack(String older) {
    content = older;
    _version++;
  }
}
