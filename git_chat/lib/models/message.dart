import 'package:hive/hive.dart';

part 'message.g.dart';

@HiveType(typeId: 0)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String from;

  @HiveField(2)
  final String to;

  @HiveField(3)
  final String body;

  @HiveField(4)
  final DateTime timestamp;

  @HiveField(5)
  int ttl;

  @HiveField(6)
  final String? groupId;

  @HiveField(7)
  final bool isRelayed;

  ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
    this.ttl = 3,
    this.groupId,
    this.isRelayed = false,
  });

  /// Convert to a Map for BLE transmission
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'from': from,
      'to': to,
      'body': body,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'ttl': ttl,
      'groupId': groupId,
      'isRelayed': isRelayed,
    };
  }

  /// Create from a Map received over BLE
  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      from: map['from'] as String,
      to: map['to'] as String,
      body: map['body'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      ttl: map['ttl'] as int? ?? 3,
      groupId: map['groupId'] as String?,
      isRelayed: map['isRelayed'] as bool? ?? false,
    );
  }
}
