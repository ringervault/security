import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_cipher.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_engine.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_payload.dart';
import 'package:ringer_vault/sync/sync_transport.dart';
import 'package:ringer_vault/sync/sync_vault.dart';

import 'support/render_harness.dart';

/// Getting passwords back after something went wrong, end to end, through
/// the real vault file and the real sync: each phone is a harness of its own
/// (its own files and keystore), and they share one Google Drive.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  const passphrase = 'a long enough sync passphrase';
  final storage = StorageService();

  VaultEntry entry(String id) =>
      VaultEntry(id: id, title: id, username: 'u', password: 'pw-$id', category: 'Banking');

  late _Drive drive;
  late RenderHarness phone;
  setUp(() => drive = _Drive());
  tearDown(() async {
    if (phone.isUp) await phone.tearDown();
  });

  /// A phone with a vault holding [ids], set up with [pin].
  Future<void> newPhone({List<String> ids = const [], String unlockWith = pin}) async {
    phone = RenderHarness();
    await phone.setUp(pin: unlockWith, entries: [for (final id in ids) entry(id)]);
  }

  /// One sync of this phone's open vault with Drive.
  Future<SyncOutcome> sync({String key = passphrase, _Marks? marks}) => SyncEngine(
        transport: drive,
        vault: StorageSyncVault(),
        cipher: SyncCipher(key),
        deviceId: 'phone',
        isStrictOffline: () => false,
        isDecoy: () => AuthService().isDecoyMode,
        marks: marks,
      ).run();

  Set<String> ids() => storage.getEntries().map((e) => e.id).toSet();

  /// The usual history: three logins synced, then one deleted after a
  /// breach and one changed, and synced again.
  Future<_Marks> history() async {
    await newPhone(ids: ['bank', 'mail', 'shop']);
    final marks = _Marks();
    await sync(marks: marks);
    await storage.deleteEntry('shop');
    await storage.updateEntry(entry('bank')..password = 'changed-after-breach');
    await sync(marks: marks);
    return marks;
  }

  void restored() {
    expect(ids(), {'bank', 'mail'}, reason: 'the deleted login stays deleted');
    expect(storage.getEntries().firstWhere((e) => e.id == 'bank').password,
        'changed-after-breach', reason: 'the change, not the old password');
  }

  test('forgotten PIN: erase this phone, set a new PIN, and Drive gives everything back', () async {
    await history();
    await AuthService().logout();
    await AuthService().eraseVault();

    await AuthService().setPin('246802');
    expect(ids(), isEmpty);
    await sync(marks: _Marks());
    restored();
  });

  test('a new phone gets everything back from Drive', () async {
    await history();
    await phone.tearDown();

    await newPhone(unlockWith: '864201');
    await sync(marks: _Marks());
    restored();
  });

  test('an exported backup file brings everything back on its own', () async {
    await history();
    final file = await storage.getEncryptedJson('backup password 1234');
    await AuthService().logout();
    await AuthService().eraseVault();

    await AuthService().setPin('246802');
    expect(await storage.importFromEncryptedJson(file, 'backup password 1234'), 2);
    restored();
  });

  test('a backup file with the wrong password brings nothing in', () async {
    await history();
    final file = await storage.getEncryptedJson('backup password 1234');
    await AuthService().logout();
    await AuthService().eraseVault();
    await AuthService().setPin('246802');

    await expectLater(storage.importFromEncryptedJson(file, 'not that one at all'), throwsA(anything));
    expect(ids(), isEmpty);
  });

  test('both copies of the vault file damaged: refused, then recovered from Drive', () async {
    await history();
    await AuthService().logout();
    for (final name in ['vault.rvc', 'vault.rvc.prev']) {
      final f = phone.file(name);
      final bytes = await f.readAsBytes();
      bytes[100] ^= 1;
      await f.writeAsBytes(bytes);
    }
    await expectLater(AuthService().verifyPin(pin), throwsA(isA<VaultTamperedError>()));

    // What the lock screen offers then: erase this phone, set up again.
    await AuthService().eraseVault();
    await AuthService().setPin('246802');
    await sync(marks: _Marks());
    restored();
  });

  test('self-destruct, then everything back from Drive', () async {
    await history();
    phone.secureStorage['self_destruct_enabled'] = 'true';
    phone.secureStorage['self_destruct_threshold'] = '3';
    await AuthService().logout();
    for (var i = 0; i < 2; i++) {
      expect(await AuthService().verifyPin('000000'), isFalse);
    }
    await expectLater(AuthService().verifyPin('000000'), throwsA(isA<VaultDestroyedException>()));
    expect(await AuthService().verifyPin(pin), isFalse, reason: 'the vault is gone');

    await AuthService().setPin('246802');
    await sync(marks: _Marks());
    restored();
  });

  test('forgotten sync passphrase: nothing is lost here, and another phone starts a new backup', () async {
    await history();
    await phone.tearDown();

    // A second phone that does not know the passphrase.
    await newPhone(ids: ['only-here'], unlockWith: '864201');
    final before = drive.content;
    await expectLater(sync(key: 'a passphrase nobody chose'), throwsA(isA<SyncPassphraseError>()));
    expect(ids(), {'only-here'}, reason: 'untouched');
    expect(drive.content, before, reason: 'and the backup untouched too');

    // What the app says to do: on a phone that still syncs, delete the
    // backup and start a new one with a new passphrase.
    await phone.tearDown();
    await newPhone(unlockWith: '135791');
    await sync(marks: _Marks()); // the first phone's data, still there
    await drive.delete();
    await sync(key: 'a brand new sync passphrase', marks: _Marks());

    await phone.tearDown();
    await newPhone(ids: ['only-here'], unlockWith: '864201');
    await sync(key: 'a brand new sync passphrase', marks: _Marks());
    expect(ids(), {'bank', 'mail', 'only-here'});
  });

  test('re-importing an old backup undoes nothing that happened since', () async {
    await newPhone(ids: ['bank', 'mail', 'shop']);
    final old = await storage.getEncryptedJson('backup password 1234');
    await storage.deleteEntry('shop');
    await storage.updateEntry(entry('bank')..password = 'changed-after-breach');
    await storage.addEntry(entry('new'));

    await storage.importFromEncryptedJson(old, 'backup password 1234');
    expect(ids(), {'bank', 'mail', 'new'}, reason: 'the deleted login stays deleted');
    expect(storage.getEntries().firstWhere((e) => e.id == 'bank').password,
        'changed-after-breach', reason: 'the newer password is kept');
  });

  test('two phones editing at once: both edits survive, the later one wins a clash', () async {
    // This phone (real storage) and a second one (in memory), both synced,
    // then both changing things before either syncs again.
    final marks = await history();
    final other = _MemoryVault();
    Future<void> syncOther() => SyncEngine(
          transport: drive,
          vault: other,
          cipher: SyncCipher(passphrase),
          deviceId: 'other',
          isStrictOffline: () => false,
          isDecoy: () => false,
          marks: other.marks,
        ).run();
    await syncOther();
    expect(other.ids, {'bank', 'mail'});

    other.edit('mail', 'edited-there-first');
    other.edit('from-there', 'pw');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await storage.updateEntry(entry('mail')..password = 'edited-here-later');
    await storage.addEntry(entry('from-here'));

    await syncOther();
    await sync(marks: marks);
    await syncOther();

    expect(ids(), {'bank', 'mail', 'from-here', 'from-there'});
    expect(other.ids, ids());
    expect(storage.getEntries().firstWhere((e) => e.id == 'mail').password, 'edited-here-later');
    expect(other.passwordOf('mail'), 'edited-here-later');
  });

  test('a sync cut off mid-upload loses nothing, and the next one finishes it', () async {
    final marks = await history();
    await storage.addEntry(entry('added-offline'));
    drive.failNextUpload = true;
    await expectLater(sync(marks: marks), throwsA(isA<SyncTransportError>()));
    expect(ids(), contains('added-offline'), reason: 'kept here');

    await sync(marks: marks);
    await phone.tearDown();
    await newPhone(unlockWith: '864201');
    await sync(marks: _Marks());
    expect(ids(), contains('added-offline'), reason: 'and reached Drive in the end');
  });

  test('a decoy does not survive recovery, and leaves nothing behind', () async {
    await history();
    await AuthService().setSecondaryPin('246801');
    await AuthService().logout();
    await AuthService().eraseVault();

    await AuthService().setPin('246802');
    await sync(marks: _Marks());
    restored();
    await AuthService().logout();
    expect(await AuthService().verifyPin('246801'), isFalse);
    expect(phone.secureStorage.keys.where((k) => k.contains('decoy')), isEmpty);
  });
}

/// Google Drive, as far as sync can tell: one file, versioned.
class _Drive implements SyncTransport {
  String? content;
  int _version = 0;

  /// The next upload fails as a dropped connection would.
  bool failNextUpload = false;

  @override
  Future<RemoteInfo?> info() async => content == null ? null : RemoteInfo(version: '$_version');

  @override
  Future<String> fetch(RemoteInfo info, {ByteProgress? onBytes}) async {
    final c = content;
    if (c == null) throw const SyncTransportError('gone');
    return c;
  }

  @override
  Future<String> upload(String data, {required String? ifVersion}) async {
    if (failNextUpload) {
      failNextUpload = false;
      throw const SyncTransportError('connection dropped');
    }
    if (ifVersion != (content == null ? null : '$_version')) throw const SyncConflict();
    content = data;
    return '${++_version}';
  }

  @override
  Future<void> delete() async {
    content = null;
    _version++;
  }
}

/// A second phone, in memory: enough of a vault for sync.
class _MemoryVault implements SyncVault {
  final Map<String, SyncRecord> _records = {};
  final marks = _Marks();

  Set<String> get ids => {for (final r in _records.values) if (!r.isDeleted) r.id};
  String? passwordOf(String id) => _records[id]?.entry?['password'] as String?;

  void edit(String id, String password) {
    final at = DateTime.now().toUtc();
    final base = Map<String, dynamic>.from(_records[id]?.entry ??
        VaultEntry(id: id, title: id, username: 'u', password: '', category: 'Banking').toJson());
    _records[id] = SyncRecord(
      id: id,
      updatedAt: at,
      entry: base..['password'] = password..['updatedAt'] = at.toIso8601String(),
    );
  }

  @override
  Map<String, SyncRecord> snapshot() => Map.of(_records);

  @override
  bool canStore(SyncRecord record) => true;

  @override
  Future<void> applyEntry(SyncRecord record) async => _records[record.id] = record;

  @override
  Future<void> applyDeletion(SyncRecord record) async => _records[record.id] = record;

  @override
  Future<void> replaceDeletions(Map<String, DateTime> deletions) async {}
}

class _Marks implements SyncMarkStore {
  SyncMark? mark;

  _Marks copy() => _Marks()..mark = mark;

  @override
  Future<SyncMark?> load() async => mark;

  @override
  Future<void> save(SyncMark m) async => mark = m;
}
