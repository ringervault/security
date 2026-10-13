import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_cipher.dart';

import 'support/render_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  late RenderHarness harness;
  final storage = StorageService();

  VaultEntry entry(String id) => VaultEntry(
        id: id, title: id, username: 'u', password: 'pw-$id', category: 'Banking');

  Uint8List randomKey() =>
      Uint8List.fromList(List<int>.generate(32, (_) => Random.secure().nextInt(256)));

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [entry('a'), entry('b')]);
  });

  tearDown(() => harness.tearDown());

  group('the cipher on its own', () {
    test('round trip', () {
      final cipher = VaultCipher(randomKey());
      final plain = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final out = Uint8List(cipher.maxEncryptedSize(plain));
      final n = cipher.encrypt(plain, 0, plain.length, out, 0);
      final back = Uint8List(n);
      final m = cipher.decrypt(out, 0, n, back, 0);
      expect(back.sublist(0, m), plain);
    });

    test('any changed byte is refused, never decrypted', () {
      final cipher = VaultCipher(randomKey());
      final plain = Uint8List.fromList(List<int>.generate(48, (i) => i));
      final out = Uint8List(cipher.maxEncryptedSize(plain));
      final n = cipher.encrypt(plain, 0, plain.length, out, 0);
      for (final at in [0, 16, n - 33, n - 1]) {
        final changed = Uint8List.fromList(out.sublist(0, n));
        changed[at] ^= 0x01;
        expect(() => cipher.decrypt(changed, 0, n, Uint8List(n), 0),
            throwsA(isA<VaultTamperedError>()), reason: 'byte $at');
      }
    });

    test('a value sealed under another vault key is refused', () {
      final plain = Uint8List.fromList([1, 2, 3]);
      final a = VaultCipher(randomKey());
      final out = Uint8List(a.maxEncryptedSize(plain));
      final n = a.encrypt(plain, 0, plain.length, out, 0);
      expect(() => VaultCipher(randomKey()).decrypt(out, 0, n, Uint8List(n), 0),
          throwsA(isA<VaultTamperedError>()));
    });
  });

  File vaultFile() => File('${harness.hiveDirPath}/vault.rvc');

  /// The vault, closed, with what the unlock that follows will run into.
  Future<Object?> unlockError() async {
    try {
      await AuthService().verifyPin(pin);
      return null;
    } catch (e) {
      return e;
    }
  }

  File prevFile() => File('${harness.hiveDirPath}/vault.rvc.prev');

  test('a changed byte in both copies is refused, and the files kept', () async {
    await AuthService().logout();
    final forged = Uint8List.fromList(await vaultFile().readAsBytes())..[100] ^= 0x01;
    await vaultFile().writeAsBytes(forged);
    final forgedPrev = Uint8List.fromList(await prevFile().readAsBytes())..[100] ^= 0x01;
    await prevFile().writeAsBytes(forgedPrev);

    expect(await unlockError(), isA<VaultTamperedError>());
    expect(await vaultFile().readAsBytes(), forged, reason: 'not "recovered" or rewritten');
  });

  test('a changed byte in the current copy only is recovered from one write back', () async {
    await AuthService().logout();
    final forged = Uint8List.fromList(await vaultFile().readAsBytes())..[100] ^= 0x01;
    await vaultFile().writeAsBytes(forged);

    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.takeRestoredFromPrevious(), isTrue, reason: 'and the user is told');
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a'},
        reason: 'the copy from before the last change, which added b');
  });

  test('an older copy of the vault file put back is refused', () async {
    await AuthService().logout();
    final older = await vaultFile().readAsBytes();
    expect(await AuthService().verifyPin(pin), isTrue);
    await storage.deleteEntry('a'); // a later change
    await AuthService().logout();

    await vaultFile().writeAsBytes(older);
    expect(await unlockError(), isA<VaultTamperedError>());
  });

  test('a deleted vault file is refused, not opened as an empty vault', () async {
    await AuthService().logout();
    await vaultFile().delete();
    await prevFile().delete();
    expect(await unlockError(), isA<VaultTamperedError>());
  });

  test('every change is in the file, whole, not only in memory', () async {
    await storage.deleteEntry('a');
    await storage.addEntry(entry('c'));
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'b', 'c'});
    expect(storage.deletions.keys, ['a']);
  });

  /// The setUp vault, rebuilt in an older format under the same key.
  Future<Uint8List> makeOldFiles({required bool hiveAes, Map<String, String> deleted = const {}}) async {
    final key = storage.activeMasterKey!;
    await AuthService().logout();
    await storage.destroyVault(isDecoy: false);
    final HiveCipher cipher = hiveAes ? HiveAesCipher(key) : VaultCipher(key);
    final old = await Hive.openBox<VaultEntry>(
        hiveAes ? StorageService.legacyRealVaultBoxName : StorageService.oldRealVaultBoxName,
        encryptionCipher: cipher);
    await old.putAll({'a': entry('a'), 'b': entry('b')});
    await old.close();
    final oldDeleted = await Hive.openBox<String>(
        hiveAes ? StorageService.legacyTombstoneBoxName : StorageService.oldRealTombstoneBoxName,
        encryptionCipher: cipher);
    await oldDeleted.putAll(deleted);
    await oldDeleted.close();
    return key;
  }

  test('a vault from the first format is moved, entries and deletions intact', () async {
    await makeOldFiles(hiveAes: true, deleted: {'z': '2026-09-01T00:00:00.000Z'});
    expect(await AuthService().verifyPin(pin), isTrue);

    expect(storage.getEntries().map((e) => e.id).toSet(), {'a', 'b'});
    expect(storage.deletions.keys, ['z']);
    expect(await Hive.boxExists(StorageService.legacyRealVaultBoxName), isFalse);
    expect(await Hive.boxExists(StorageService.legacyTombstoneBoxName), isFalse);
    expect(await vaultFile().exists(), isTrue);
  });

  test('a vault and its log from the second format are moved', () async {
    final key = await makeOldFiles(hiveAes: false, deleted: {'z': '2026-09-01T00:00:00.000Z'});
    final log = await Hive.openBox<Map>(StorageService.oldRealLogBoxName,
        encryptionCipher: HiveAesCipher(key));
    await log.add({'timestamp': DateTime.now().toIso8601String(), 'action': 'Old event'});
    await log.close();

    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a', 'b'});
    expect(storage.deletions.keys, ['z']);
    expect(storage.vaultLog.map((l) => l['action']), contains('Old event'));
    for (final name in [
      StorageService.oldRealVaultBoxName,
      StorageService.oldRealTombstoneBoxName,
      StorageService.oldRealLogBoxName,
    ]) {
      expect(await Hive.boxExists(name), isFalse, reason: name);
    }
  });

  test('a move interrupted before it finished runs again from the old file', () async {
    final key = await makeOldFiles(hiveAes: true);
    // What an earlier interrupted move left: a half-written newer file.
    final half = await Hive.openBox<VaultEntry>(StorageService.oldRealVaultBoxName,
        encryptionCipher: VaultCipher(key));
    await half.put('a', entry('a'));
    await half.close();

    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a', 'b'});
  });

  test('the files on disk say nothing about a decoy', () async {
    Future<Map<String, int>> files() async => {
          for (final f in Directory(harness.hiveDirPath).listSync().whereType<File>())
            f.uri.pathSegments.last: f.lengthSync(),
        };
    final before = await files();

    await AuthService().setSecondaryPin('246801');
    await AuthService().logout();
    expect(await AuthService().verifyPin('246801'), isTrue);
    expect(storage.isDecoyMode, isTrue);
    await storage.addEntry(entry('decoy-entry'));
    await AuthService().logout();

    final after = await files();
    expect(after.keys.where((n) => n.toLowerCase().contains('decoy')), isEmpty);
    expect(after['vault.rvc'], before['vault.rvc'], reason: 'the same size with a decoy');
    expect(after.keys.where((n) => n.startsWith('vault2') || n.startsWith('vault_log')), isEmpty);

    // And each still opens only its own.
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a', 'b'});
  });
}
