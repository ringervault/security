import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/vault_lock.dart';

/// Autofill runs in a second Flutter engine, which is a second isolate with
/// its own Hive. Two isolates appending to one box file corrupts it, and a
/// corrupted vault is data nobody can recover. This lock is what stops that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ringer_lock_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await VaultLock.resetForTest();
  });

  tearDown(() async {
    VaultLock.askHolderToRelease = null;
    await VaultLock.resetForTest();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a free vault can be taken', () async {
    expect(await VaultLock.acquire(), isTrue);
    expect(VaultLock.isHeldByThisIsolate, isTrue);
  });

  test('taking it twice from the same isolate is fine', () async {
    // Reopening the vault in the same isolate is normal: switching vaults
    // closes one box and opens another.
    expect(await VaultLock.acquire(), isTrue);
    expect(await VaultLock.acquire(), isTrue);
  });

  test('refuses while another isolate holds it', () async {
    await VaultLock.takeAsOtherIsolate();
    expect(await VaultLock.acquire(), isFalse);
  });

  test('takes over a lock that was abandoned', () async {
    // A process killed mid-session must not lock the owner out for good.
    await VaultLock.takeAsOtherIsolate(
      age: VaultLock.staleAfter + const Duration(minutes: 1),
    );
    expect(await VaultLock.acquire(), isTrue);
  });

  test('a lock left by an app that was closed is taken over at once', () async {
    // The phone case: the app was swiped away while unlocked, so the next
    // launch found a lock from a process that no longer exists and refused a
    // correct PIN for fifteen minutes.
    await VaultLock.takeAsEndedProcess();
    expect(await VaultLock.acquire(), isTrue);
  });

  test('a lock in the old format is taken over', () async {
    // Written by a build that installing this one replaced, and installing
    // a build ends the process that ran the old one.
    await VaultLock.takeInOldFormat();
    expect(await VaultLock.acquire(), isTrue);
  });

  test('releasing frees it for the other isolate', () async {
    expect(await VaultLock.acquire(), isTrue);
    await VaultLock.release();

    expect(VaultLock.isHeldByThisIsolate, isFalse);
    expect(File('${dir.path}/vault.open').existsSync(), isFalse);
  });

  test('never releases a lock belonging to someone else', () async {
    await VaultLock.takeAsOtherIsolate();
    await VaultLock.release();

    expect(File('${dir.path}/vault.open').existsSync(), isTrue,
        reason: 'stealing the lock is how two isolates end up writing at once');
  });

  group('the main app asks the autofill screen to let go', () {
    test('and gets the vault once it has', () async {
      await VaultLock.takeAsOtherIsolate();
      var asked = 0;
      VaultLock.askHolderToRelease = () async {
        asked++;
        await VaultLock.resetForTest(); // The holder closes and releases.
        return true;
      };

      expect(await VaultLock.acquireOrAsk(), isTrue);
      expect(asked, 1);
      expect(VaultLock.isHeldByThisIsolate, isTrue);
    });

    test('does not ask when the vault is free', () async {
      var asked = 0;
      VaultLock.askHolderToRelease = () async {
        asked++;
        return true;
      };
      expect(await VaultLock.acquireOrAsk(), isTrue);
      expect(asked, 0);
    });

    test('stays out if the holder does not let go', () async {
      await VaultLock.takeAsOtherIsolate();
      VaultLock.askHolderToRelease = () async => true;
      expect(await VaultLock.acquireOrAsk(), isFalse);
    });

    test('stays out if asking fails', () async {
      await VaultLock.takeAsOtherIsolate();
      VaultLock.askHolderToRelease = () async => throw StateError('no engine');
      expect(await VaultLock.acquireOrAsk(), isFalse);
    });

    test('the autofill screen itself never asks', () async {
      await VaultLock.takeAsOtherIsolate();
      expect(VaultLock.askHolderToRelease, isNull);
      expect(await VaultLock.acquireOrAsk(), isFalse);
    });
  });
}
