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
  String body; // mutable for in-place editing

  @HiveField(4)
  final DateTime timestamp;

  @HiveField(5)
  int ttl;

  @HiveField(6)
  final String? groupId;

  @HiveField(7)
  final bool isRelayed;

  @HiveField(8)
  bool isEdited;

  @HiveField(9)
  bool isDeleted;

  /// 'text' | 'image' | 'link'
  @HiveField(10)
  String messageType;

  ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
    this.ttl = 3,
    this.groupId,
    this.isRelayed = false,
    this.isEdited = false,
    this.isDeleted = false,
    this.messageType = 'text',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'from': from,
    'to': to,
    'body': body,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'ttl': ttl,
    'groupId': groupId,
    'isRelayed': isRelayed,
    'isEdited': isEdited,
    'isDeleted': isDeleted,
    'messageType': messageType,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] as String,
    from: map['from'] as String,
    to: map['to'] as String,
    body: map['body'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
    ttl: map['ttl'] as int? ?? 3,
    groupId: map['groupId'] as String?,
    isRelayed: map['isRelayed'] as bool? ?? false,
    isEdited: map['isEdited'] as bool? ?? false,
    isDeleted: map['isDeleted'] as bool? ?? false,
    messageType: map['messageType'] as String? ?? 'text',
  );
}
