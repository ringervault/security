import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_merge.dart';
import 'package:ringer_vault/sync/sync_payload.dart';

/// The backup file is the contract between the app and the browser
/// extension, and each side reads it with a different implementation: the app
/// through package:cryptography, the extension through WebCrypto.
///
/// Both use PBKDF2-SHA256 and AES-256-GCM, so neither writes a line of
/// cryptography itself, but the byte layout around them is hand-rolled on
/// both sides. These tests hand a real file from one to the other, so a
/// change to the layout cannot pass unnoticed.
void main() {
  final repoRoot = Directory.current.path;
  final cli = '$repoRoot/extension/test/decrypt_cli.mjs';

  Future<ProcessResult> decryptWithExtension(
    String backup,
    String password,
  ) async {
    final process = await Process.start('node', [cli, password]);
    process.stdin.write(backup);
    await process.stdin.close();

    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return ProcessResult(process.pid, code, stdout, stderr);
  }

  const password = 'correct horse battery staple';

  final entries = [
    {
      'id': 'e1',
      'title': 'Chase',
      'username': 'ada',
      'email': '',
      'password': 'a-password-with-üñïçødé-and-"quotes"',
      'category': 'Banking',
      'notes': 'line one\nline two',
      'autofillTargets': ['site:chase.com'],
    },
    {
      'id': 'e2',
      'title': 'GitHub',
      'username': '',
      'email': 'ada@example.com',
      'password': r'p@$$w0rd\with\backslashes',
      'category': 'Work',
      'notes': '',
      'autofillTargets': ['site:github.com', 'app:com.github.android:ab12'],
    },
  ];

  test('a backup written by the app opens in the extension', () async {
    final backup = await StorageService().encryptData(
      utf8.encode(jsonEncode(entries)),
      password,
    );

    final result = await decryptWithExtension(backup, password);
    expect(
      result.exitCode,
      0,
      reason: 'extension could not read an app backup: ${result.stderr}',
    );

    final decoded = jsonDecode(result.stdout as String) as List<dynamic>;
    expect(decoded.length, 2);

    final chase = decoded.firstWhere((e) => e['id'] == 'e1');
    expect(chase['title'], 'Chase');
    expect(chase['password'], 'a-password-with-üñïçødé-and-"quotes"');
    expect(chase['autofillTargets'], ['site:chase.com']);

    final github = decoded.firstWhere((e) => e['id'] == 'e2');
    expect(github['email'], 'ada@example.com');
    expect(github['password'], r'p@$$w0rd\with\backslashes');
  });

  test('the wrong password is refused rather than guessed at', () async {
    final backup = await StorageService().encryptData(
      utf8.encode(jsonEncode(entries)),
      password,
    );

    final result = await decryptWithExtension(backup, 'not the password');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Incorrect password'));
  });

  test('a modified backup is refused, not partially read', () async {
    // AES-GCM authenticates, so flipping a byte of ciphertext has to be
    // caught. Without that, a file edited in transit could change what gets
    // typed into a login form.
    final backup = await StorageService().encryptData(
      utf8.encode(jsonEncode(entries)),
      password,
    );

    final bytes = base64Decode(backup);
    bytes[bytes.length - 1] ^= 0x01;

    final result = await decryptWithExtension(base64Encode(bytes), password);
    expect(result.exitCode, isNot(0));
  });

  group('the Google Drive sync file', () {
    SyncPayload payload() => SyncPayload(
          writtenBy: 'phone',
          writtenAt: DateTime.utc(2026, 9, 1),
          records: {
            'e1': SyncRecord(
              id: 'e1',
              updatedAt: DateTime.utc(2026, 9, 1),
              entry: entries[0],
            ),
            'gone': SyncRecord.deleted(
              id: 'gone',
              updatedAt: DateTime.utc(2026, 9, 2),
            ),
          },
        );

    test('a sync file written by the app opens in the extension', () async {
      final file = await payload().encrypt(SyncCipher(password));
      final result = await decryptWithExtension(file, password);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final decoded = jsonDecode(result.stdout as String) as List<dynamic>;
      expect(decoded.map((e) => e['id']), ['e1']);
      expect(decoded.single['password'],
          'a-password-with-üñïçødé-and-"quotes"');
    });

    test('a file written with a reused salt still opens in the extension',
        () async {
      // The app now reuses the backup's salt to skip the slow key derivation
      // on every write. The extension derives from whatever salt the file
      // carries, so this must make no difference to it.
      final cipher = SyncCipher(password);
      final first = await payload().encrypt(cipher);
      await cipher.decrypt(first); // as a sync does: read, then write
      final second = await payload().encrypt(cipher);

      expect(second.substring(0, 20), first.substring(0, 20),
          reason: 'same salt');
      final result = await decryptWithExtension(second, password);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('a deleted entry is not offered by the extension', () async {
      // A deleted password showing up in the browser would undo the reason
      // it was deleted.
      final file = await payload().encrypt(SyncCipher(password));
      final result = await decryptWithExtension(file, password);

      expect(result.stdout, isNot(contains('gone')));
    });

    test('a sync file from a newer app is refused, not misread', () async {
      final newer = await StorageService().encryptData(
        utf8.encode(jsonEncode({
          'format': SyncPayload.formatName,
          'version': SyncPayload.currentVersion + 1,
          'records': [],
        })),
        password,
      );
      final result = await decryptWithExtension(newer, password);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('newer version'));
    });
  });

  group('a login saved by the extension', () {
    final saveCli = '$repoRoot/extension/test/save_cli.mjs';

    Future<String> saveWithExtension(
      String file, {
      required String url,
      required String username,
      required String newPassword,
    }) async {
      final process = await Process.start(
        'node',
        [saveCli, password, url, username, newPassword],
      );
      process.stdin.write(file);
      await process.stdin.close();
      final out = await process.stdout.transform(utf8.decoder).join();
      final err = await process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 0, reason: err);
      return out;
    }

    // An entry exactly as the phone stores it, every field included.
    final chase = VaultEntry(
      id: 'chase',
      title: 'Chase',
      username: 'ada',
      password: 'old-password',
      category: 'Banking',
      pin: '4321',
      extraPassword: 'transaction-password',
      extraPasswordLabel: 'Transaction',
      notes: 'kept',
      autofillTargets: const ['site:chase.com'],
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );

    SyncPayload phoneCopy() => SyncPayload(
          writtenBy: 'phone',
          writtenAt: DateTime.utc(2026, 9, 1),
          records: {
            'chase': SyncRecord(
              id: 'chase',
              updatedAt: DateTime.utc(2026, 9, 1),
              entry: chase.toJson(),
            ),
            'gone': SyncRecord.deleted(
              id: 'gone',
              updatedAt: DateTime.utc(2026, 9, 2),
            ),
          },
        );

    test('a changed password updates the entry and keeps every field',
        () async {
      final cipher = SyncCipher(password);
      final saved = await saveWithExtension(
        await phoneCopy().encrypt(cipher),
        url: 'https://chase.com/login',
        username: 'ada',
        newPassword: 'new-password',
      );

      final opened = await SyncPayload.decrypt(saved, SyncCipher(password));
      final record = opened.records['chase']!;
      expect(record.updatedAt.isAfter(DateTime.utc(2026, 9, 1)), isTrue);

      final entry = VaultEntry.fromJson(record.entry!);
      expect(entry.password, 'new-password');
      expect(entry.pin, '4321');
      expect(entry.extraPassword, 'transaction-password');
      expect(entry.notes, 'kept');
      expect(entry.autofillTargets, ['site:chase.com']);
      expect(opened.records['gone']!.isDeleted, isTrue,
          reason: 'a deletion dropped here would bring the password back');
    });

    test('a new login is an entry the phone reads and merges in', () async {
      final saved = await saveWithExtension(
        await phoneCopy().encrypt(SyncCipher(password)),
        url: 'https://www.example.org/signin',
        username: 'grace@example.org',
        newPassword: 'typed-in-chrome',
      );
      final opened = await SyncPayload.decrypt(saved, SyncCipher(password));
      final added = opened.records.values.firstWhere(
        (r) => !r.isDeleted && r.id != 'chase',
      );

      final entry = VaultEntry.fromJson(added.entry!);
      expect(entry.title, 'Example');
      expect(entry.email, 'grace@example.org');
      expect(entry.password, 'typed-in-chrome');
      expect(entry.autofillTargets, ['site:example.org']);

      // The phone, holding its own copy, takes the new entry on next sync.
      final result = merge(local: phoneCopy().records, remote: opened.records);
      expect(result.upsertLocally, contains(added.id));
      expect(result.merged['chase']!.entry!['password'], 'old-password');
    });
  });

  test('a vault created by the extension opens in the app, and takes its '
      'entries', () async {
    final created = await Process.run(
      'node',
      ['$repoRoot/extension/test/create_cli.mjs', password],
    );
    expect(created.exitCode, 0, reason: '${created.stderr}');

    final opened = await SyncPayload.decrypt(
      created.stdout as String,
      SyncCipher(password),
    );
    expect(opened.records, isEmpty);

    // The phone joins with its own entries: they all go up, nothing is lost.
    final local = {
      'e1': SyncRecord(
        id: 'e1',
        updatedAt: DateTime.utc(2026, 9, 1),
        entry: entries[0],
      ),
    };
    final result = merge(local: local, remote: opened.records);
    expect(result.remoteChanged, isTrue);
    expect(result.merged.keys, ['e1']);
  });

  test('a file that is not a backup at all is rejected', () async {
    final result = await decryptWithExtension(
      base64Encode(utf8.encode('hello')),
      password,
    );
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('not a Ringer Vault backup'));
  });
}
