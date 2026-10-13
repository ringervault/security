import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:ringer_vault/sync/sync_cipher.dart';
import 'package:ringer_vault/sync/sync_merge.dart';

/// The file that sits in Google Drive.
///
/// Its outer layer is the same encrypted format as an exported backup,
/// Argon2id and AES-256-GCM under a passphrase only the user knows, so
/// Google holds ciphertext and nothing else, and the browser extension opens
/// it with the code it already uses for backups.
///
/// Inside is a small envelope rather than a bare list of entries, because a
/// synced copy has to carry deletions, and a format that cannot say what
/// version it is cannot ever change safely.
class SyncPayload {
  static const String formatName = 'ringer-vault-sync';

  /// 2 added [generation]. A build that knows only 1 refuses to write a
  /// version 2 file, rather than writing one back without the counter,
  /// which every other device would then take for an old copy put back.
  static const int currentVersion = 2;

  final Map<String, SyncRecord> records;
  final String writtenBy;
  final DateTime writtenAt;

  /// One more than the generation of the copy it replaced. Inside the
  /// encryption, so nobody without the passphrase can raise it: an older
  /// copy put back in Drive has a lower number than one a device already
  /// accepted, whatever any clock says. 0 for files from before it existed.
  final int generation;

  const SyncPayload({
    required this.records,
    required this.writtenBy,
    required this.writtenAt,
    this.generation = 0,
  });

  String toJsonString() => jsonEncode({
        'format': formatName,
        'version': currentVersion,
        'writtenBy': writtenBy,
        'writtenAt': writtenAt.toUtc().toIso8601String(),
        'generation': generation,
        'records': [for (final r in records.values) r.toJson()],
      });

  /// Parses a decrypted payload.
  ///
  /// A file written by a newer version of the app is refused rather than
  /// half-read: merging records whose meaning this build does not know, then
  /// writing them back, is how a newer device's data gets damaged by an
  /// older one.
  static SyncPayload parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const SyncPayloadError('The synced copy is damaged.');
    }
    if (decoded is! Map || decoded['format'] != formatName) {
      throw const SyncPayloadError(
        'The file in Google Drive is not a Ringer Vault sync file.',
      );
    }

    final version = decoded['version'];
    if (version is! int || version > currentVersion) {
      throw const SyncPayloadError(
        'The synced copy was written by a newer version of Ringer Vault. '
        'Update the app on this device before syncing.',
      );
    }

    final rawRecords = decoded['records'];
    final generation = decoded['generation'] ?? 0;
    if (rawRecords is! List || generation is! int || generation < 0) {
      throw const SyncPayloadError('The synced copy is damaged.');
    }

    final records = <String, SyncRecord>{};
    for (final raw in rawRecords) {
      final record = SyncRecord.tryParse(raw);
      // Skipping it would let the next write drop it from every device
      // without anyone being told, so the whole copy is refused instead.
      if (record == null) {
        throw const SyncPayloadError(
          'The synced copy is damaged: part of it cannot be read. Nothing '
          'was changed on either side.',
        );
      }
      // Two records for one id would mean the file was assembled wrongly.
      // Keep the one that would win a merge anyway.
      final existing = records[record.id];
      records[record.id] =
          existing == null ? record : pickWinner(existing, record);
    }

    return SyncPayload(
      records: records,
      writtenBy: decoded['writtenBy'] is String ? decoded['writtenBy'] : '',
      writtenAt: DateTime.tryParse('${decoded['writtenAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      generation: generation,
    );
  }

  /// Writing and reading the JSON for a whole vault both run on a
  /// background isolate, like the encryption itself, so the screen keeps
  /// moving while a large vault is synced.
  Future<String> encrypt(SyncCipher cipher) async =>
      cipher.encrypt(await compute(_encode, this));

  /// Throws [SyncPassphraseError] when the passphrase does not open the file,
  /// which AES-GCM makes indistinguishable from the file having been altered.
  static Future<SyncPayload> decrypt(String content, SyncCipher cipher) async {
    final List<int> plain;
    try {
      plain = await cipher.decrypt(content);
    } on SyncCipherError {
      throw const SyncPassphraseError();
    }
    return compute(_decode, plain);
  }

  static List<int> _encode(SyncPayload payload) =>
      utf8.encode(payload.toJsonString());

  static SyncPayload _decode(List<int> plain) {
    final String json;
    try {
      json = utf8.decode(plain);
    } on FormatException {
      throw const SyncPayloadError('The synced copy is damaged.');
    }
    return parse(json);
  }
}

class SyncPayloadError implements Exception {
  final String message;
  const SyncPayloadError(this.message);

  @override
  String toString() => message;
}

class SyncPassphraseError implements Exception {
  const SyncPassphraseError();

  @override
  String toString() =>
      'The sync passphrase does not open the copy in Google Drive, or that '
      'copy has been altered. Nothing was changed on either side.';
}
