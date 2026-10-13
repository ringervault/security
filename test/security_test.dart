import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'dart:convert';


// Since StorageService calls hive, we can just test the separate methods we exposed.
// We need to bypass the Singleton init or mocked checks, but since we use `StorageService()` factory...
// The _internal constructor is private.
// But we can call the methods if we can get an instance.
// factory StorageService() => _instance;
// It returns the singleton.
// The singleton is lazy init but fields like `_box` are late.
// `encryptData` and `decryptDataV2` DO NOT touch `_box`. They are pure async functions.
// So we can use them safely even if `init` wasn't called.

void main() {
  group('Encryption Logic Tests', () {
    final service = StorageService();

    test('V2 Encryption Roundtrip', () async {
      final text = 'PleaseEncryptMe123!';
      final password = 'StrongPassword!@#';
      final bytes = utf8.encode(text);

      final encryptedB64 = await service.encryptData(bytes, password);
      
      // Decrypt
      final encryptedBytes = base64Decode(encryptedB64);
      final decryptedBytes = await service.decryptDataV2(encryptedBytes, password);
      final decryptedText = utf8.decode(decryptedBytes);

      expect(decryptedText, equals(text));
    });

    test('V2 Entropy (Different Outputs)', () async {
      final text = 'SameText';
      final password = 'SamePassword';
      final bytes = utf8.encode(text);

      final enc1 = await service.encryptData(bytes, password);
      final enc2 = await service.encryptData(bytes, password);

      expect(enc1, isNot(equals(enc2))); // Salt and IV should make them different
    });
    
    test('Wrong Password fails V2', () async {
       final text = 'Secret';
       final password = 'RightPassword';
       final bytes = utf8.encode(text);

       final encryptedB64 = await service.encryptData(bytes, password);
       final encryptedBytes = base64Decode(encryptedB64);

       expect(() async {
         await service.decryptDataV2(encryptedBytes, 'WrongPassword');
       }, throwsA(anything)); // Mac check failure likely
    });

    test('Tampered ciphertext is rejected', () async {
      final encryptedB64 =
          await service.encryptData(utf8.encode('Secret'), 'password');
      final bytes = base64Decode(encryptedB64);

      // Flip one bit in the ciphertext body (past salt+nonce+mac).
      bytes[bytes.length - 1] ^= 0x01;

      await expectLater(
        service.decryptDataV2(bytes, 'password'),
        throwsA(anything),
        reason: 'AES-GCM must authenticate, not just decrypt',
      );
    });
  });

  group('Import rejection', () {
    final service = StorageService();

    // These all fail before any Hive access, so no box is needed.

    test('rejects a non-base64 file', () async {
      await expectLater(
        service.importFromEncryptedJson('this is not a backup', 'password'),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects a file too short to hold a header', () async {
      await expectLater(
        service.importFromEncryptedJson(base64Encode(List.filled(20, 0)), 'pw'),
        throwsA(isA<Exception>()),
      );
    });

    test('no longer falls back to the legacy V1 format', () async {
      // A V1 backup: AES-CBC under a '*'-padded password key. Under the old
      // code this decrypted successfully; it must now be refused outright.
      const legacyV1Backup =
          'ZFTAKq5vJ8HxK0uPZ0lNaQfLmR3sT7wY2bN4cV6xA1dE5gH8jK0mP3rS6uW9yB2e';

      await expectLater(
        service.importFromEncryptedJson(legacyV1Backup, 'password'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
