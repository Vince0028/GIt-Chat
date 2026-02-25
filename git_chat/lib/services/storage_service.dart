import 'package:hive_flutter/hive_flutter.dart';
import '../models/message.dart';

class StorageService {
  static const String _messagesBox = 'messages';
  static const String _profileBox = 'profile';
  static const String _usernameKey = 'username';
  static const String _userIdKey = 'userId';

  /// Initialize Hive and register adapters
  static Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(ChatMessageAdapter());
    await Hive.openBox<ChatMessage>(_messagesBox);
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

  static List<ChatMessage> getMessages({String? peerId}) {
    final box = Hive.box<ChatMessage>(_messagesBox);
    final all = box.values.toList();

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

    return all..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  static bool hasMessage(String id) {
    final box = Hive.box<ChatMessage>(_messagesBox);
    return box.containsKey(id);
  }

  static Future<void> clearMessages() async {
    final box = Hive.box<ChatMessage>(_messagesBox);
    await box.clear();
  }
}
