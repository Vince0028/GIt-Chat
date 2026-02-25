import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../services/ble_service.dart';
import '../services/storage_service.dart';

/// Mesh relay service implementing a Gossip Protocol.
///
/// How it works:
/// 1. When a message is received, check if we've seen it before (by ID)
/// 2. If new, store it and re-broadcast with TTL decremented
/// 3. Messages with TTL=0 are NOT relayed (they die)
/// 4. A "seen set" prevents infinite loops
class MeshService extends ChangeNotifier {
  final BLEService _bleService;
  final Set<String> _seenMessageIds = {};
  final List<ChatMessage> _pendingRelay = [];
  StreamSubscription<ChatMessage>? _incomingSub;
  Timer? _relayTimer;
  int _relayedCount = 0;
  int _droppedCount = 0;

  // ── Getters ──────────────────────────────────────────
  int get relayedCount => _relayedCount;
  int get droppedCount => _droppedCount;
  int get pendingCount => _pendingRelay.length;
  int get seenCount => _seenMessageIds.length;

  MeshService(this._bleService) {
    // Listen for all incoming messages
    _incomingSub = _bleService.incomingMessages.listen(_onMessageReceived);

    // Periodic relay attempt for store-and-forward
    _relayTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _attemptPendingRelay(),
    );
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _relayTimer?.cancel();
    super.dispose();
  }

  // ── Core Gossip Logic ────────────────────────────────

  void _onMessageReceived(ChatMessage message) {
    // 1. Have we seen this message before?
    if (_seenMessageIds.contains(message.id)) {
      _droppedCount++;
      debugPrint('[MESH] Dropped duplicate: ${message.id.substring(0, 8)}');
      notifyListeners();
      return;
    }

    // 2. Mark as seen
    _seenMessageIds.add(message.id);

    // 3. Save locally if addressed to us or broadcast
    final myUsername = StorageService.getUsername() ?? '';
    if (message.to == myUsername || message.to == 'broadcast') {
      StorageService.saveMessage(message);
    }

    // 4. Should we relay?
    if (message.ttl > 0) {
      // Decrement TTL and queue for relay
      final relayMsg = ChatMessage(
        id: message.id,
        from: message.from,
        to: message.to,
        body: message.body,
        timestamp: message.timestamp,
        ttl: message.ttl - 1,
        groupId: message.groupId,
        isRelayed: true,
      );

      _scheduleRelay(relayMsg);
    } else {
      _droppedCount++;
      debugPrint('[MESH] TTL expired: ${message.id.substring(0, 8)}');
    }

    notifyListeners();
  }

  void _scheduleRelay(ChatMessage message) {
    _pendingRelay.add(message);
    // Attempt immediate relay
    _relayNow(message);
  }

  Future<void> _relayNow(ChatMessage message) async {
    final connectedPeers = _bleService.peers.where((p) => p.isConnected);

    if (connectedPeers.isEmpty) {
      debugPrint(
        '[MESH] No peers to relay to, stored for later: ${message.id.substring(0, 8)}',
      );
      return;
    }

    // Broadcast to all connected peers
    await _bleService.broadcastMessage(message);
    _relayedCount++;
    _pendingRelay.removeWhere((m) => m.id == message.id);

    debugPrint(
      '[MESH] Relayed: ${message.id.substring(0, 8)} '
      '(TTL: ${message.ttl}, peers: ${connectedPeers.length})',
    );

    notifyListeners();
  }

  /// Attempt to flush pending (store-and-forward) messages
  void _attemptPendingRelay() {
    if (_pendingRelay.isEmpty) return;

    final connectedPeers = _bleService.peers.where((p) => p.isConnected);
    if (connectedPeers.isEmpty) return;

    debugPrint(
      '[MESH] Attempting to relay ${_pendingRelay.length} pending messages...',
    );

    // Copy list to avoid concurrent modification
    final toRelay = List<ChatMessage>.from(_pendingRelay);
    for (final msg in toRelay) {
      _relayNow(msg);
    }
  }

  /// Mark a message ID as "seen" to prevent relay loops
  /// Call this when sending your own messages
  void markAsSeen(String messageId) {
    _seenMessageIds.add(messageId);
  }

  /// Clean up old seen IDs to prevent memory bloat
  /// Call periodically (e.g., every hour)
  void cleanupSeenIds({int maxSize = 10000}) {
    if (_seenMessageIds.length > maxSize) {
      final toRemove = _seenMessageIds.length - maxSize;
      final ids = _seenMessageIds.toList();
      for (int i = 0; i < toRemove; i++) {
        _seenMessageIds.remove(ids[i]);
      }
      debugPrint('[MESH] Cleaned up $toRemove old message IDs');
    }
  }
}
