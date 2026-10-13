import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_cipher.dart';

import 'support/render_harness.dart';

/// The process killed at every step of a write, and of moving an old vault
/// in: whatever stops where, both vaults open afterwards, holding either
/// what they held before the write or what the write put there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '482916';
  const decoyPin = '246801';
  late RenderHarness harness;
  final storage = StorageService();

  VaultEntry entry(String id) =>
      VaultEntry(id: id, title: id, username: 'u', password: 'pw-$id', category: 'Banking');

  File file(String suffix) => File('${harness.hiveDirPath}/vault.rvc$suffix');

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [entry('a')]);
    // A decoy with something in it, so its slot has to survive too.
    await AuthService().setSecondaryPin(decoyPin);
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue);
    await storage.addEntry(entry('decoy-only'));
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
  });

  tearDown(() async {
    StorageService.debugFault = null;
    await harness.tearDown();
  });

  /// What the next start finds in each vault.
  Future<(Set<String>, Set<String>)> afterRestart() async {
    StorageService.debugFault = null;
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue, reason: 'the real vault opens');
    final real = storage.getEntries().map((e) => e.id).toSet();
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue, reason: 'the decoy opens');
    final decoy = storage.getEntries().map((e) => e.id).toSet();
    return (real, decoy);
  }

  /// Stops the next write at [step], as a killed process would.
  void crashAt(String step, {Future<void> Function(File)? first}) {
    StorageService.debugFault = (s, f) async {
      if (s != step) return;
      await first?.call(f);
      throw const _Killed();
    };
  }

  for (final step in ['sealed', 'written', 'kept-previous', 'committed']) {
    test('killed at "$step": nothing is lost', () async {
      crashAt(step);
      await expectLater(storage.addEntry(entry('b')), throwsA(isA<_Killed>()));

      final (real, decoy) = await afterRestart();
      expect(real, anyOf({'a'}, {'a', 'b'}), reason: 'before or after, never neither');
      expect(decoy, {'decoy-only'});
      if (step == 'kept-previous' || step == 'committed') {
        expect(real, {'a', 'b'}, reason: 'the next file was whole, so it is finished');
      }
    });
  }

  test('a half-written next file is dropped, not opened', () async {
    crashAt('written', first: (f) async {
      final bytes = await f.readAsBytes();
      await f.writeAsBytes(bytes.sublist(0, bytes.length ~/ 3), flush: true);
    });
    await expectLater(storage.addEntry(entry('b')), throwsA(isA<_Killed>()));

    final (real, decoy) = await afterRestart();
    expect(real, {'a'});
    expect(decoy, {'decoy-only'});
    expect(await file('.new').exists(), isFalse);
  });

  test('a torn next file with no current file is not taken for a vault', () async {
    crashAt('kept-previous');
    await expectLater(storage.addEntry(entry('b')), throwsA(isA<_Killed>()));
    // As if the flush had not reached the disk after all.
    final next = file('.new');
    await next.writeAsBytes((await next.readAsBytes()).sublist(0, 100));

    StorageService.debugFault = null;
    await AuthService().logout();
    // Not silently empty: the previous copy, one write back, is offered.
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a'});
    expect(storage.takeRestoredFromPrevious(), isTrue);
  });

  test('damage to this vault\'s part of the file falls back one write', () async {
    await storage.addEntry(entry('b'));
    await AuthService().logout();
    final bytes = Uint8List.fromList(await file('').readAsBytes());
    bytes[200] ^= 1; // inside the real slot
    await file('').writeAsBytes(bytes);

    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'a'},
        reason: 'the copy from before the last change');
    expect(storage.takeRestoredFromPrevious(), isTrue);
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isTrue);
    expect(storage.getEntries().map((e) => e.id).toSet(), {'decoy-only'});
  });

  test('the previous copy is never a way to put back an older one', () async {
    await AuthService().logout();
    final older = await file('').readAsBytes();
    expect(await AuthService().verifyPin(pin), isTrue);
    await storage.addEntry(entry('b'));
    await storage.addEntry(entry('c'));
    await AuthService().logout();
    // Two writes back, planted as the previous copy, beside a damaged one.
    await file('.prev').writeAsBytes(older);
    final bytes = Uint8List.fromList(await file('').readAsBytes())..[200] ^= 1;
    await file('').writeAsBytes(bytes);

    await expectLater(AuthService().verifyPin(pin), throwsA(isA<VaultTamperedError>()));
  });

  test('erasing the decoy erases it from the previous copy too', () async {
    await storage.addEntry(entry('b')); // the previous copy now holds the decoy too
    Uint8List decoyPart(Uint8List f) => f.sublist(8 + (f.length - 8) ~/ 2);
    final decoyBefore = decoyPart(await file('').readAsBytes());
    expect(decoyPart(await file('.prev').readAsBytes()), decoyBefore);

    await AuthService().setSecondaryPin('');
    expect(decoyPart(await file('').readAsBytes()), isNot(decoyBefore));
    expect(decoyPart(await file('.prev').readAsBytes()), isNot(decoyBefore),
        reason: 'not left behind one write back');
    await AuthService().logout();
    expect(await AuthService().verifyPin(decoyPin), isFalse);
  });

  test('on a new phone the old file opens nothing, and a new vault starts cleanly', () async {
    // What a copied app folder looks like there: the vault file, but none
    // of the keys, which never leave the old phone's keystore.
    await AuthService().logout();
    harness.secureStorage.clear();
    await AuthService().setPin('111222');
    expect(storage.isReady, isTrue);
    expect(storage.getEntries(), isEmpty);
    await storage.addEntry(entry('new-phone'));
    await AuthService().logout();

    expect(await AuthService().verifyPin('111222'), isTrue);
    expect(storage.getEntries().map((e) => e.id), ['new-phone']);
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isFalse);
    expect(await AuthService().verifyPin(decoyPin), isFalse);
  });

  group('moving an old vault in', () {
    Future<void> oldVault() async {
      final key = storage.activeMasterKey!;
      await AuthService().logout();
      await storage.destroyVault(isDecoy: false);
      final old = await Hive.openBox<VaultEntry>(StorageService.legacyRealVaultBoxName,
          encryptionCipher: HiveAesCipher(key));
      await old.putAll({'a': entry('a'), 'old': entry('old')});
      await old.close();
    }

    for (final step in ['written', 'kept-previous', 'committed', 'moved']) {
      test('killed at "$step": the move finishes on the next start', () async {
        await oldVault();
        crashAt(step);
        await expectLater(AuthService().verifyPin(pin), throwsA(isA<_Killed>()));

        final (real, decoy) = await afterRestart();
        expect(real, {'a', 'old'});
        expect(decoy, {'decoy-only'});
        expect(await Hive.boxExists(StorageService.legacyRealVaultBoxName), isFalse,
            reason: 'the old file goes once the move is safe');
      });
    }
  });
}

class _Killed implements Exception {
  const _Killed();
}