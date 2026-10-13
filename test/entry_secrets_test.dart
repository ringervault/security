import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ringer_vault/models/vault_entry.dart';

/// Writes an entry the way the app did before labels and second secrets
/// existed: ten fields, nothing beyond field 9.
class _LegacyVaultEntryAdapter extends TypeAdapter<VaultEntry> {
  @override
  final int typeId = 0;

  @override
  VaultEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return VaultEntry(
      id: fields[0] as String?,
      title: fields[1] as String,
      username: fields[2] as String,
      password: fields[3] as String,
      category: fields[4] as String,
      email: fields[8] as String,
      pin: fields[9] as String,
      notes: fields[5] as String?,
      createdAt: fields[6] as DateTime?,
      updatedAt: fields[7] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, VaultEntry obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.username)
      ..writeByte(3)
      ..write(obj.password)
      ..writeByte(4)
      ..write(obj.category)
      ..writeByte(5)
      ..write(obj.notes)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.updatedAt)
      ..writeByte(8)
      ..write(obj.email)
      ..writeByte(9)
      ..write(obj.pin);
  }
}

void main() {
  VaultEntry entry({
    String password = 'pw',
    String passwordLabel = '',
    String extraPassword = '',
    String extraPasswordLabel = '',
    String pin = '',
    String pinLabel = '',
    String extraPin = '',
    String extraPinLabel = '',
  }) =>
      VaultEntry(
        id: 'id-1',
        title: 'Chase',
        username: 'jdoe',
        email: 'j@example.com',
        category: 'Banking',
        notes: 'branch account',
        password: password,
        passwordLabel: passwordLabel,
        extraPassword: extraPassword,
        extraPasswordLabel: extraPasswordLabel,
        pin: pin,
        pinLabel: pinLabel,
        extraPin: extraPin,
        extraPinLabel: extraPinLabel,
      );

  group('the secrets an entry exposes', () {
    test('lists only the ones that hold a value', () {
      final e = entry(password: 'pw', pin: '1234');
      expect(e.secrets.map((s) => s.value), ['pw', '1234']);
    });

    test('lists all four when all four are used', () {
      final e = entry(
        password: 'login-pw',
        passwordLabel: 'Login password',
        extraPassword: 'txn-pw',
        extraPasswordLabel: 'Transaction password',
        pin: '1234',
        pinLabel: 'ATM PIN',
        extraPin: '654321',
        extraPinLabel: 'TPIN',
      );

      expect(
        e.secrets.map((s) => '${s.label}=${s.value}'),
        [
          'Login password=login-pw',
          'Transaction password=txn-pw',
          'ATM PIN=1234',
          'TPIN=654321',
        ],
      );
      expect(e.secrets.map((s) => s.isPin), [false, false, true, true]);
    });

    test('falls back to a generic name when no label was given', () {
      // Every entry saved before labels existed is in this state.
      final e = entry(password: 'pw', pin: '1234');
      expect(e.secrets[0].label, 'Password');
      expect(e.secrets[1].label, 'PIN');
    });

    test('trims a label and ignores one that is only spaces', () {
      final e = entry(password: 'pw', passwordLabel: '  Card password  ');
      expect(e.secrets.single.label, 'Card password');
      expect(entry(password: 'pw', passwordLabel: '   ').secrets.single.label,
          'Password');
    });

    test('is empty when the entry holds nothing', () {
      expect(entry(password: '').secrets, isEmpty);
    });
  });

  group('searchable text', () {
    test('includes the labels', () {
      final e = entry(pin: '1234', pinLabel: 'TPIN');
      expect(e.searchableLabels, contains('TPIN'));
    });

    test('never includes a value', () {
      final e = entry(
        password: 'sup3rsecret',
        pin: '987654',
        extraPassword: 'other-secret',
        extraPin: '1111',
      );

      for (final value in ['sup3rsecret', '987654', 'other-secret', '1111']) {
        expect(e.searchableLabels, isNot(contains(value)),
            reason: 'a search must never be able to confirm a guess');
      }
    });
  });

  group('backup format', () {
    test('round-trips every field', () {
      final original = entry(
        password: 'login-pw',
        passwordLabel: 'Login password',
        extraPassword: 'txn-pw',
        extraPasswordLabel: 'Transaction password',
        pin: '1234',
        pinLabel: 'ATM PIN',
        extraPin: '654321',
        extraPinLabel: 'TPIN',
      );

      final restored = VaultEntry.fromJson(original.toJson());

      expect(restored.password, original.password);
      expect(restored.passwordLabel, 'Login password');
      expect(restored.extraPassword, 'txn-pw');
      expect(restored.extraPasswordLabel, 'Transaction password');
      expect(restored.pin, '1234');
      expect(restored.pinLabel, 'ATM PIN');
      expect(restored.extraPin, '654321');
      expect(restored.extraPinLabel, 'TPIN');
    });

    test('restores a backup taken before these fields existed', () {
      final old = {
        'id': 'id-1',
        'title': 'Chase',
        'username': 'jdoe',
        'password': 'pw',
        'category': 'Banking',
        'email': 'j@example.com',
        'pin': '1234',
        'notes': null,
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
      };

      final restored = VaultEntry.fromJson(old);

      expect(restored.password, 'pw');
      expect(restored.pin, '1234');
      expect(restored.extraPassword, isEmpty);
      expect(restored.secrets.map((s) => s.label), ['Password', 'PIN']);
    });
  });

  group('copyWith', () {
    test('keeps labels that were not passed', () {
      final e = entry(password: 'pw', passwordLabel: 'Login password');
      expect(e.copyWith(password: 'new-pw').passwordLabel, 'Login password');
    });

    test('can clear a secret and its label together', () {
      final e = entry(password: 'pw', extraPin: '1234', extraPinLabel: 'TPIN');
      final cleared = e.copyWith(extraPin: '', extraPinLabel: '');
      expect(cleared.secrets.map((s) => s.label), ['Password']);
    });
  });

  group('stored format', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ringer_entry_test');
      Hive.init(dir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await Hive.close();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('reads an entry written by the previous version of the app', () async {
      // The real risk of adding fields: every entry already on a user's phone
      // was written without them, and a non-nullable cast on read would make
      // the whole vault unreadable.
      Hive.registerAdapter(_LegacyVaultEntryAdapter(), override: true);
      var box = await Hive.openBox<VaultEntry>('legacy_entries');
      await box.put('a', entry(password: 'old-pw', pin: '1234'));
      await box.close();

      Hive.registerAdapter(VaultEntryAdapter(), override: true);
      box = await Hive.openBox<VaultEntry>('legacy_entries');
      final loaded = box.get('a')!;

      expect(loaded.password, 'old-pw');
      expect(loaded.pin, '1234');
      expect(loaded.passwordLabel, isEmpty);
      expect(loaded.extraPassword, isEmpty);
      expect(loaded.extraPin, isEmpty);
      expect(loaded.secrets.map((s) => s.label), ['Password', 'PIN']);
      expect(loaded.autofillTargets, isEmpty,
          reason: 'autofill targets were added later still');
      expect(loaded.targets, isEmpty);
    });

    test('round-trips autofill targets', () async {
      Hive.registerAdapter(VaultEntryAdapter(), override: true);
      var box = await Hive.openBox<VaultEntry>('target_entries');
      await box.put(
        'a',
        entry(password: 'pw')
          ..autofillTargets = [
            'site:chase.com',
            'app:com.chase.mobile:'
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ],
      );
      await box.close();

      box = await Hive.openBox<VaultEntry>('target_entries');
      final loaded = box.get('a')!;

      expect(loaded.targets, hasLength(2));
      expect(loaded.targets.first.value, 'chase.com');
      expect(loaded.targets.last.isPinned, isTrue);
    });

    test('round-trips the new fields', () async {
      Hive.registerAdapter(VaultEntryAdapter(), override: true);
      var box = await Hive.openBox<VaultEntry>('new_entries');
      await box.put(
        'a',
        entry(
          password: 'pw',
          passwordLabel: 'Login password',
          extraPassword: 'txn',
          extraPasswordLabel: 'Transaction password',
          pin: '1234',
          pinLabel: 'ATM PIN',
          extraPin: '654321',
          extraPinLabel: 'TPIN',
        ),
      );
      await box.close();

      box = await Hive.openBox<VaultEntry>('new_entries');
      final loaded = box.get('a')!;

      expect(loaded.extraPasswordLabel, 'Transaction password');
      expect(loaded.extraPin, '654321');
      expect(loaded.secrets.length, 4);
    });
  });
}
