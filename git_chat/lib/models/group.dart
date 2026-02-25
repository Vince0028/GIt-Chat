import 'package:hive/hive.dart';

part 'group.g.dart';

@HiveType(typeId: 1)
class MeshGroup extends HiveObject {
  @HiveField(0)
  final String id; // Unique GroupID e.g. "APC_HACKERS_99"

  @HiveField(1)
  final String name; // Display name

  @HiveField(2)
  final String createdBy; // Username of creator

  @HiveField(3)
  final DateTime createdAt;

  @HiveField(4)
  final List<String> members; // List of usernames in this group

  @HiveField(5)
  final String symmetricKey; // Shared secret for the group (base64)

  @HiveField(6)
  final String? password; // Optional password to join this group

  MeshGroup({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.members,
    required this.symmetricKey,
    this.password,
  });

  /// Convert to Map for BLE transmission (invites)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'createdBy': createdBy,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'members': members,
      'symmetricKey': symmetricKey,
      'password': password,
    };
  }

  factory MeshGroup.fromMap(Map<String, dynamic> map) {
    return MeshGroup(
      id: map['id'] as String,
      name: map['name'] as String,
      createdBy: map['createdBy'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      members: List<String>.from(map['members'] as List),
      symmetricKey: map['symmetricKey'] as String,
      password: map['password'] as String?,
    );
  }
}
