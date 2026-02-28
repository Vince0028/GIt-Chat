import 'package:hive_flutter/hive_flutter.dart';
import '../models/message.dart';
import '../models/group.dart';

class StorageService {
  static const String _messagesBox = 'messages';
  static const String _profileBox = 'profile';
  static const String _groupsBox = 'groups';
  static const String _usernameKey = 'username';
  static const String _userIdKey = 'userId';

  /// Initialize Hive and register adapters
  static Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(ChatMessageAdapter());
    Hive.registerAdapter(MeshGroupAdapter());
    await Hive.openBox<ChatMessage>(_messagesBox);
    await Hive.openBox<MeshGroup>(_groupsBox);
    await Hive.openBox(_profileBox);
  }

  // ── Profile ──────────────────────────────────────────

  static Future<void> saveUsername(String username) async {
    final box = Hive.box(_profileBox);
    await box.put(_usernameKey, username);
  }

  static String? getUsername() {
    final box = Hive.box(_profileBox);
    return box.get(_usernameKey) as String?;
  }

  static Future<void> saveUserId(String id) async {
    final box = Hive.box(_profileBox);
    await box.put(_userIdKey, id);
  }

  static String? getUserId() {
    final box = Hive.box(_profileBox);
    return box.get(_userIdKey) as String?;
  }

  // ── Messages ─────────────────────────────────────────

  static Future<void> saveMessage(ChatMessage message) async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    await box.put(message.id, message);
  }

  static Future<void> editMessage(String id, String newBody) async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final msg = box.get(id);
    if (msg == null) return;
    msg.body = newBody;
    msg.isEdited = true;
    await msg.save();
  }

  static Future<void> deleteMessage(String id) async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final msg = box.get(id);
    if (msg == null) return;
    msg.isDeleted = true;
    await msg.save();
  }

  static List<ChatMessage> getMessages({String? peerId, String? groupId}) {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final all = box.values.toList();

    if (groupId != null) {
      return all.where((m) => m.groupId == groupId).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    if (peerId != null) {
      final username = getUsername() ?? '';
      return all
          .where(
            (m) =>
                (m.from == username && m.to == peerId) ||
                (m.from == peerId && m.to == username),
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    // Return only broadcast (non-group) messages
    return all.where((m) => m.groupId == null || m.groupId!.isEmpty).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  static bool hasMessage(String id) {
    final box = Hive.box<ChatMessage>(_messagesBox);
    return box.containsKey(id);
  }

  static Future<void> clearMessages() async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    await box.clear();
  }

  // ── Groups ───────────────────────────────────────────

  static Future<void> saveGroup(MeshGroup group) async {
    final box = Hive.box<MeshGroup>(_groupsBox);
    await box.put(group.id, group);
  }

  static List<MeshGroup> getGroups() {
    final box = Hive.box<MeshGroup>(_groupsBox);
    return box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static MeshGroup? getGroup(String groupId) {
    final box = Hive.box<MeshGroup>(_groupsBox);
    return box.get(groupId);
  }

  static bool isGroupMember(String groupId) {
    final group = getGroup(groupId);
    if (group == null) return false;
    final username = getUsername() ?? '';
    return group.members.contains(username);
  }

  static Future<void> addMemberToGroup(String groupId, String username) async {
    final group = getGroup(groupId);
    if (group == null) return;
    if (!group.members.contains(username)) {
      group.members.add(username);
      await group.save();
    }
  }

  static Future<void> deleteGroup(String groupId) async {
    final box = Hive.box<MeshGroup>(_groupsBox);
    await box.delete(groupId);
  }

  /// Delete all messages in a specific group
  static Future<void> clearGroupMessages(String groupId) async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final keysToDelete = box.keys.where((key) {
      final msg = box.get(key);
      return msg != null && msg.groupId == groupId;
    }).toList();
    await box.deleteAll(keysToDelete);
  }

  /// Delete all broadcast (non-group) messages
  static Future<void> clearBroadcastMessages() async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final keysToDelete = box.keys.where((key) {
      final msg = box.get(key);
      return msg != null && (msg.groupId == null || msg.groupId!.isEmpty);
    }).toList();
    await box.deleteAll(keysToDelete);
  }

  /// Remove a member from a group
  static Future<void> removeMemberFromGroup(String groupId, String username) async {
    final group = getGroup(groupId);
    if (group == null) return;
    group.members.remove(username);
    await group.save();
  }

  /// Rename a group
  static Future<void> renameGroup(String groupId, String newName) async {
    final box = Hive.box<MeshGroup>(_groupsBox);
    final group = box.get(groupId);
    if (group == null) return;
    // MeshGroup.name is final, so we need to create a new one
    final updated = MeshGroup(
      id: group.id,
      name: newName,
      createdBy: group.createdBy,
      createdAt: group.createdAt,
      members: group.members,
      symmetricKey: group.symmetricKey,
      password: group.password,
    );
    await box.put(groupId, updated);
  }

  /// Get the last message in a group for preview
  static ChatMessage? getLastGroupMessage(String groupId) {
    final msgs = getMessages(groupId: groupId);
    return msgs.isNotEmpty ? msgs.last : null;
  }
}
