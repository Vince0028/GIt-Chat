// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'group.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MeshGroupAdapter extends TypeAdapter<MeshGroup> {
  @override
  final int typeId = 1;

  @override
  MeshGroup read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MeshGroup(
      id: fields[0] as String,
      name: fields[1] as String,
      createdBy: fields[2] as String,
      createdAt: fields[3] as DateTime,
      members: (fields[4] as List).cast<String>(),
      symmetricKey: fields[5] as String,
      password: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, MeshGroup obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.createdBy)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.members)
      ..writeByte(5)
      ..write(obj.symmetricKey)
      ..writeByte(6)
      ..write(obj.password);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshGroupAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
