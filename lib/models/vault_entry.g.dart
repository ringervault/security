// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class VaultEntryAdapter extends TypeAdapter<VaultEntry> {
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
      // Fields 10 and up were added later. Entries written before then have
      // no bytes for them, so each is read as nullable and defaulted rather
      // than cast, which would throw on every pre-existing entry.
      passwordLabel: fields[10] as String? ?? '',
      extraPassword: fields[11] as String? ?? '',
      extraPasswordLabel: fields[12] as String? ?? '',
      pinLabel: fields[13] as String? ?? '',
      extraPin: fields[14] as String? ?? '',
      extraPinLabel: fields[15] as String? ?? '',
      autofillTargets: (fields[16] as List?)?.cast<String>(),
      createdAt: fields[6] as DateTime?,
      updatedAt: fields[7] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, VaultEntry obj) {
    writer
      ..writeByte(17)
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
      ..write(obj.pin)
      ..writeByte(10)
      ..write(obj.passwordLabel)
      ..writeByte(11)
      ..write(obj.extraPassword)
      ..writeByte(12)
      ..write(obj.extraPasswordLabel)
      ..writeByte(13)
      ..write(obj.pinLabel)
      ..writeByte(14)
      ..write(obj.extraPin)
      ..writeByte(15)
      ..write(obj.extraPinLabel)
      ..writeByte(16)
      ..write(obj.autofillTargets);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
