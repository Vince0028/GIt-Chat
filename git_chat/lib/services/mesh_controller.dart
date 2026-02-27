import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/group.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';

/// Represents a peer connected via Nearby Connections API
class MeshPeer {
  final String endpointId;
  final String endpointName;
  bool isConnected;
  DateTime lastSeen;

  MeshPeer({
    required this.endpointId,
    required this.endpointName,
    this.isConnected = false,
  }) : lastSeen = DateTime.now();
}

/// Packet types for the mesh protocol
enum MeshPacketType {
  message,
  groupInvite,
  groupJoinAck,
  messageEdit,
  messageDelete,
  imageMetadata, // legacy (kept for index compatibility)
  imageChunk, // chunked image data sent via bytes payload
}

/// A wrapper for all data sent over the mesh
class MeshPacket {
  final MeshPacketType type;
  final Map<String, dynamic> payload;

  MeshPacket({required this.type, required this.payload});

  Map<String, dynamic> toMap() => {'type': type.index, 'payload': payload};

  factory MeshPacket.fromMap(Map<String, dynamic> map) {
    return MeshPacket(
      type: MeshPacketType.values[map['type'] as int],
      payload: Map<String, dynamic>.from(map['payload'] as Map),
    );
  }
}

/// The core intelligence of the Serverless Mesh.
/// Uses Google's Nearby Connections (P2P_CLUSTER)
/// which uses Bluetooth, BLE, and Wi-Fi Direct seamlessly.
class MeshController extends ChangeNotifier {
  final Strategy strategy = Strategy.P2P_CLUSTER;
  static const String _serviceId = 'com.gitchat.mesh';

  final Map<String, MeshPeer> _peers = {};
  bool _isAdvertising = false;
  bool _isDiscovering = false;

  // Image chunking — collect incoming chunks until all arrive
  // messageId -> { 'totalChunks': int, 'meta': Map, 'chunks': Map<int,String> }
  final Map<String, Map<String, dynamic>> _chunkCollectors = {};

  // Large image file payload tracking
  final Map<int, String> _pendingImageFiles = {}; // payloadId -> temp file path
  final Map<int, Map<String, dynamic>> _pendingImageMeta =
      {}; // payloadId -> metadata
  final Map<int, String> _payloadToMsgId = {}; // payloadId -> messageId
  final Map<String, double> _fileTransferProgress = {}; // messageId -> 0.0..1.0

  final StreamController<ChatMessage> _incomingMessages =
      StreamController<ChatMessage>.broadcast();

  final StreamController<MeshGroup> _incomingGroupInvites =
      StreamController<MeshGroup>.broadcast();

  final StreamController<MeshGroup> _passwordProtectedInvites =
      StreamController<MeshGroup>.broadcast();

  final Set<String> _seenMessageIds = {};

  // ── Getters ──────────────────────────────────────────
  List<MeshPeer> get connectedPeers =>
      _peers.values.where((p) => p.isConnected).toList();
  Map<String, MeshPeer> get allPeers => Map.unmodifiable(_peers);
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  bool get isMeshActive => _isAdvertising || _isDiscovering;
  Stream<ChatMessage> get incomingMessages => _incomingMessages.stream;
  Stream<MeshGroup> get incomingGroupInvites => _incomingGroupInvites.stream;
  Stream<MeshGroup> get passwordProtectedInvites =>
      _passwordProtectedInvites.stream;
  Map<String, double> get fileTransferProgress =>
      Map.unmodifiable(_fileTransferProgress);

  // ── Lifecycle ────────────────────────────────────────

  /// Returns (and creates if needed) the persistent directory for mesh images
  Future<String> getImagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/mesh_images');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  void dispose() {
    stopMesh();
    _incomingMessages.close();
    _incomingGroupInvites.close();
    _passwordProtectedInvites.close();
    super.dispose();
  }

  // ── Mesh Activation ──────────────────────────────────

  /// Starts the Dual Loop: Advertising & Discovering simultaneously
  Future<void> startMesh() async {
    final hasPerms = await PermissionService.requestPermissions();
    if (!hasPerms) {
      final missing = await PermissionService.getMissingPermissions();
      debugPrint('[MESH] ❌ Cannot start mesh. Missing: $missing');
      return; // Stop here — don't attempt to advertise/discover without perms
    }

    final username = StorageService.getUsername() ?? 'anon';

    // Start Beacon (Advertising)
    try {
      _isAdvertising = await Nearby().startAdvertising(
        username,
        strategy,
        onConnectionInitiated: _onConnectionInit,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      debugPrint('[MESH] Advertising started: $_isAdvertising');
    } catch (e) {
      debugPrint('[MESH] Advertising failed: $e');
    }

    // Start Radar (Discovering)
    try {
      _isDiscovering = await Nearby().startDiscovery(
        username,
        strategy,
        onEndpointFound: (id, name, serviceId) async {
          debugPrint(
            '[MESH] Found peer: $name ($id). Delaying to avoid collision...',
          );

          if (_peers.containsKey(id) && _peers[id]!.isConnected) return;

          // CRITICAL FIX: Random jitter (500-2000ms) to prevent P2P_CLUSTER
          // simultaneous connection collisions (both devices requesting at the exact same millisecond)
          await Future.delayed(
            Duration(milliseconds: 500 + Random().nextInt(1500)),
          );

          try {
            await Nearby().requestConnection(
              username,
              id,
              onConnectionInitiated: _onConnectionInit,
              onConnectionResult: _onConnectionResult,
              onDisconnected: _onDisconnected,
            );
          } catch (e) {
            debugPrint('[MESH] Connection request failed: $e');
          }
        },
        onEndpointLost: (id) {
          debugPrint('[MESH] Lost peer from radar: $id');
        },
        serviceId: _serviceId,
      );
      debugPrint('[MESH] Discovery started: $_isDiscovering');
    } catch (e) {
      debugPrint('[MESH] Discovery failed: $e');
    }

    notifyListeners();
  }

  void stopMesh() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    _isAdvertising = false;
    _isDiscovering = false;
    _peers.clear();
    notifyListeners();
  }

  // ── Connection Callbacks ─────────────────────────────

  void _onConnectionInit(String id, ConnectionInfo info) async {
    debugPrint('[MESH] Handshake with ${info.endpointName} ($id)...');
    await Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) {
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          _handleIncomingPayload(payload.bytes!, endpointId);
        } else if (payload.type == PayloadType.FILE) {
          final path = payload.uri ?? payload.filePath;
          if (path != null) {
            debugPrint('[MESH] FILE payload incoming id=${payload.id} → $path');
            final resolvedPath = path.startsWith('file://')
                ? Uri.parse(path).toFilePath()
                : path;
            _pendingImageFiles[payload.id] = resolvedPath;
          }
        }
      },
      onPayloadTransferUpdate: (endpointId, update) {
        // Track progress for large image transfers
        final msgId = _payloadToMsgId[update.id];
        if (msgId != null && update.totalBytes > 0) {
          _fileTransferProgress[msgId] =
              update.bytesTransferred / update.totalBytes;
          notifyListeners();
        }
        if (update.status == PayloadStatus.SUCCESS) {
          debugPrint('[MESH] Transfer ${update.id} SUCCESS');
          if (msgId != null) {
            _fileTransferProgress.remove(msgId);
            _payloadToMsgId.remove(update.id);
          }
          _tryProcessImage(update.id);
        } else if (update.status == PayloadStatus.FAILURE) {
          debugPrint('[MESH] Transfer ${update.id} FAILED');
          _pendingImageFiles.remove(update.id);
          _pendingImageMeta.remove(update.id);
          if (msgId != null) {
            _fileTransferProgress.remove(msgId);
            _payloadToMsgId.remove(update.id);
          }
          notifyListeners();
        }
      },
    );
    // Only create a new peer entry if _onConnectionResult hasn't already done so.
    // This avoids overwriting isConnected=true with a stale false value.
    if (!_peers.containsKey(id)) {
      _peers[id] = MeshPeer(endpointId: id, endpointName: info.endpointName);
    } else {
      _peers[id]!.lastSeen = DateTime.now();
    }
  }

  void _onConnectionResult(String id, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('[MESH] Connected to peer: $id!');
      if (_peers.containsKey(id)) {
        _peers[id]!.isConnected = true;
        _peers[id]!.lastSeen = DateTime.now();
      } else {
        _peers[id] = MeshPeer(
          endpointId: id,
          endpointName: 'peer',
          isConnected: true,
        );
      }
      notifyListeners();
    } else {
      debugPrint('[MESH] Connection failed or rejected: $id');
      _peers.remove(id);
      notifyListeners();
    }
  }

  void _onDisconnected(String id) {
    debugPrint('[MESH] Disconnected from peer: $id');
    _peers.remove(id);
    notifyListeners();
  }

  // ── Packet Router ────────────────────────────────────

  void _handleIncomingPayload(Uint8List bytes, String sourceId) {
    try {
      final jsonStr = utf8.decode(bytes);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Try new packet format first, fall back to raw message
      if (map.containsKey('type') && map.containsKey('payload')) {
        final packet = MeshPacket.fromMap(map);
        switch (packet.type) {
          case MeshPacketType.message:
            _handleIncomingMessage(
              ChatMessage.fromMap(packet.payload),
              sourceId,
            );
            break;
          case MeshPacketType.groupInvite:
            _handleGroupInvite(MeshGroup.fromMap(packet.payload), sourceId);
            break;
          case MeshPacketType.groupJoinAck:
            _handleGroupJoinAck(packet.payload, sourceId);
            break;
          case MeshPacketType.messageEdit:
            _handleIncomingEdit(packet.payload);
            break;
          case MeshPacketType.messageDelete:
            _handleIncomingDelete(packet.payload);
            break;
          case MeshPacketType.imageMetadata:
            _handleImageMetadata(packet.payload, sourceId);
            break;
          case MeshPacketType.imageChunk:
            _handleImageChunk(packet.payload, sourceId);
            break;
        }
      } else {
        // Legacy: raw ChatMessage
        _handleIncomingMessage(ChatMessage.fromMap(map), sourceId);
      }
    } catch (e) {
      debugPrint('[MESH] Failed to parse payload from $sourceId: $e');
    }
  }

  // ── Message Handling ─────────────────────────────────

  void _handleIncomingMessage(ChatMessage message, String sourceId) {
    // Deduplication
    if (_seenMessageIds.contains(message.id)) {
      debugPrint('[MESH] Dropping duplicate: ${message.id.substring(0, 6)}');
      return;
    }
    _seenMessageIds.add(message.id);

    debugPrint('[MESH] Received msg from $sourceId: ${message.body}');

    final myUsername = StorageService.getUsername() ?? 'anon';
    bool isForMe = false;

    if (message.groupId != null && message.groupId!.isNotEmpty) {
      // Group message — check if I'm a member
      isForMe = StorageService.isGroupMember(message.groupId!);
    } else {
      // Broadcast or DM
      isForMe = (message.to == myUsername || message.to == 'broadcast');
    }

    if (isForMe) {
      StorageService.saveMessage(message);
      _incomingMessages.add(message);
    }

    // Relay if TTL > 0
    if (message.ttl > 0) {
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
      debugPrint('[MESH] Relaying message (TTL=${relayMsg.ttl})...');
      _sendPacketToPeers(
        MeshPacket(type: MeshPacketType.message, payload: relayMsg.toMap()),
        excludeId: sourceId,
      );
    }
  }

  // ── Image Chunk Handling ─────────────────────────────

  /// Max bytes for a single chunk's base64 data (leaves room for JSON wrapper)
  static const int _chunkDataSize = 28000;

  void _handleImageChunk(Map<String, dynamic> data, String sourceId) {
    final msgId = data['messageId'] as String?;
    final chunkIndex = data['chunkIndex'] as int?;
    final totalChunks = data['totalChunks'] as int?;
    final chunkData = data['data'] as String?;
    if (msgId == null ||
        chunkIndex == null ||
        totalChunks == null ||
        chunkData == null)
      return;

    if (_seenMessageIds.contains(msgId)) return; // already fully received

    // Init collector if first chunk for this message
    if (!_chunkCollectors.containsKey(msgId)) {
      _chunkCollectors[msgId] = {
        'totalChunks': totalChunks,
        'meta': data['meta'] as Map<String, dynamic>? ?? {},
        'chunks': <int, String>{},
      };
    }

    final collector = _chunkCollectors[msgId]!;
    final chunks = collector['chunks'] as Map<int, String>;
    chunks[chunkIndex] = chunkData;

    // Store meta from any chunk that has it (chunk 0 always carries it)
    if (data.containsKey('meta') && data['meta'] != null) {
      collector['meta'] = data['meta'] as Map<String, dynamic>;
    }

    debugPrint(
      '[MESH] Chunk $chunkIndex/${totalChunks} for ${msgId.substring(0, 6)}',
    );

    // Check if all chunks arrived
    if (chunks.length == totalChunks) {
      _assembleImage(msgId, collector);
    }
  }

  void _assembleImage(String msgId, Map<String, dynamic> collector) {
    _chunkCollectors.remove(msgId);
    final totalChunks = collector['totalChunks'] as int;
    final chunks = collector['chunks'] as Map<int, String>;
    final meta = collector['meta'] as Map<String, dynamic>;

    // Concatenate chunks in order
    final buffer = StringBuffer();
    for (int i = 0; i < totalChunks; i++) {
      if (!chunks.containsKey(i)) {
        debugPrint('[MESH] Missing chunk $i for $msgId — dropping image');
        return;
      }
      buffer.write(chunks[i]!);
    }
    final fullBase64 = buffer.toString();

    final myUsername = StorageService.getUsername() ?? 'anon';
    bool isForMe = false;
    final groupId = meta['groupId'] as String?;
    if (groupId != null && groupId.isNotEmpty) {
      isForMe = StorageService.isGroupMember(groupId);
    } else {
      final to = meta['to'] as String? ?? 'broadcast';
      isForMe = (to == myUsername || to == 'broadcast');
    }
    if (!isForMe) return;

    final message = ChatMessage(
      id: msgId,
      from: meta['from'] as String? ?? 'anon',
      to: meta['to'] as String? ?? 'broadcast',
      body: fullBase64,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        meta['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
      ttl: 0,
      groupId: groupId,
      messageType: 'image',
    );

    _seenMessageIds.add(msgId);
    StorageService.saveMessage(message);
    _incomingMessages.add(message);
    notifyListeners();
    debugPrint(
      '[MESH] ✅ Image assembled: ${msgId.substring(0, 6)} (${fullBase64.length} chars)',
    );
  }

  // ── Large Image File Handling ────────────────────────

  void _handleImageMetadata(Map<String, dynamic> data, String sourceId) {
    final rawPayloadId = data['payloadId'];
    if (rawPayloadId == null) return;
    final payloadId = (rawPayloadId as num).toInt();
    final msgId = data['id'] as String?;
    debugPrint('[MESH] Got image metadata for payloadId=$payloadId');
    _pendingImageMeta[payloadId] = data;
    if (msgId != null) {
      _payloadToMsgId[payloadId] = msgId;
      _fileTransferProgress[msgId] = 0.0;
      notifyListeners();
    }
    _tryProcessImage(payloadId);
  }

  void _tryProcessImage(int payloadId) {
    if (_pendingImageFiles.containsKey(payloadId) &&
        _pendingImageMeta.containsKey(payloadId)) {
      final tempPath = _pendingImageFiles.remove(payloadId)!;
      final meta = _pendingImageMeta.remove(payloadId)!;
      _saveAndEmitImage(tempPath, meta);
    }
  }

  Future<void> _saveAndEmitImage(
    String tempPath,
    Map<String, dynamic> meta,
  ) async {
    try {
      final msgId = meta['id'] as String;
      final imagesDir = await getImagesDir();
      final destPath = '$imagesDir/$msgId.jpg';
      await File(tempPath).copy(destPath);
      debugPrint('[MESH] Image saved to $destPath');

      // Clean up progress tracking
      _fileTransferProgress.remove(msgId);

      final myUsername = StorageService.getUsername() ?? 'anon';
      bool isForMe = false;
      final groupId = meta['groupId'] as String?;
      if (groupId != null && groupId.isNotEmpty) {
        isForMe = StorageService.isGroupMember(groupId);
      } else {
        final to = meta['to'] as String? ?? '';
        isForMe = (to == myUsername || to == 'broadcast');
      }
      if (!isForMe) return;

      final message = ChatMessage(
        id: msgId,
        from: meta['from'] as String,
        to: meta['to'] as String,
        body: destPath,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          meta['timestamp'] as int,
        ),
        ttl: 0,
        groupId: groupId,
        messageType: 'image_file',
      );

      if (_seenMessageIds.contains(msgId)) return;
      _seenMessageIds.add(msgId);
      StorageService.saveMessage(message);
      _incomingMessages.add(message);
      notifyListeners();
    } catch (e) {
      debugPrint('[MESH] Failed to save received image: $e');
    }
  }

  // ── Group Invite Handling ────────────────────────────

  void _handleGroupInvite(MeshGroup group, String sourceId) {
    debugPrint('[MESH] Received group invite: ${group.name} from $sourceId');

    // If already a member, skip
    if (StorageService.isGroupMember(group.id)) return;

    // If group has a password, don't auto-join — ask user first
    if (group.password != null && group.password!.isNotEmpty) {
      debugPrint('[MESH] Group "${group.name}" is password-protected.');
      _passwordProtectedInvites.add(group);
      notifyListeners();
      return;
    }

    // No password — auto-join
    StorageService.saveGroup(group);
    _incomingGroupInvites.add(group);
    notifyListeners();
  }

  void _handleGroupJoinAck(Map<String, dynamic> data, String sourceId) {
    final groupId = data['groupId'] as String?;
    final username = data['username'] as String?;
    if (groupId != null && username != null) {
      StorageService.addMemberToGroup(groupId, username);
      debugPrint('[MESH] $username joined group $groupId');
      notifyListeners();
    }
  }

  // ── Public API: Send Messages ────────────────────────

  /// Send a message (broadcast or group)
  Future<void> broadcastLocalMessage(ChatMessage message) async {
    _seenMessageIds.add(message.id);
    StorageService.saveMessage(message);
    await _sendPacketToPeers(
      MeshPacket(type: MeshPacketType.message, payload: message.toMap()),
    );
  }

  /// Send an image by chunking base64 data into multiple bytes payloads
  Future<void> sendChunkedImage(ChatMessage meta) async {
    if (_seenMessageIds.contains(meta.id)) return;
    _seenMessageIds.add(meta.id);
    StorageService.saveMessage(meta); // save sender's copy
    notifyListeners();

    final peers = connectedPeers;
    if (peers.isEmpty) return;

    final base64Data = meta.body; // base64 encoded image
    final totalChunks = (base64Data.length / _chunkDataSize).ceil();
    debugPrint(
      '[MESH] Sending image ${meta.id.substring(0, 6)} in $totalChunks chunks',
    );

    final metaMap = {
      'from': meta.from,
      'to': meta.to,
      'groupId': meta.groupId,
      'timestamp': meta.timestamp.millisecondsSinceEpoch,
    };

    for (int i = 0; i < totalChunks; i++) {
      final start = i * _chunkDataSize;
      final end = (start + _chunkDataSize).clamp(0, base64Data.length);
      final chunkData = base64Data.substring(start, end);

      final chunkPayload = <String, dynamic>{
        'messageId': meta.id,
        'chunkIndex': i,
        'totalChunks': totalChunks,
        'data': chunkData,
      };
      // Attach message metadata to chunk 0 so receiver knows who/where
      if (i == 0) chunkPayload['meta'] = metaMap;

      final packet = MeshPacket(
        type: MeshPacketType.imageChunk,
        payload: chunkPayload,
      );
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));

      for (final peer in peers) {
        try {
          await Nearby().sendBytesPayload(peer.endpointId, bytes);
        } catch (e) {
          debugPrint('[MESH] Chunk $i failed to ${peer.endpointId}: $e');
        }
      }
    }
    debugPrint(
      '[MESH] ✅ All $totalChunks chunks sent for ${meta.id.substring(0, 6)}',
    );
  }

  /// Send a large image via sendFilePayload (Wi-Fi Direct) with progress
  Future<void> sendLargeImage(ChatMessage meta, String filePath) async {
    if (_seenMessageIds.contains(meta.id)) return;
    _seenMessageIds.add(meta.id);
    StorageService.saveMessage(meta);
    _fileTransferProgress[meta.id] = 0.0;
    notifyListeners();

    final peers = connectedPeers;
    if (peers.isEmpty) {
      _fileTransferProgress.remove(meta.id);
      notifyListeners();
      return;
    }

    for (final peer in peers) {
      try {
        final payloadId = await Nearby().sendFilePayload(
          peer.endpointId,
          filePath,
        );
        _payloadToMsgId[payloadId] = meta.id;
        debugPrint(
          '[MESH] sendFilePayload id=$payloadId to ${peer.endpointId}',
        );

        // Send metadata so receiver knows which message this file belongs to
        final metaMap = {...meta.toMap(), 'payloadId': payloadId};
        final metaPacket = MeshPacket(
          type: MeshPacketType.imageMetadata,
          payload: metaMap,
        );
        final bytes = Uint8List.fromList(
          utf8.encode(jsonEncode(metaPacket.toMap())),
        );
        await Nearby().sendBytesPayload(peer.endpointId, bytes);
      } catch (e) {
        debugPrint('[MESH] Large image send failed to ${peer.endpointId}: $e');
      }
    }
  }

  /// Edit a local message and propagate the change to all connected peers
  Future<void> broadcastEdit(String messageId, String newBody) async {
    await StorageService.editMessage(messageId, newBody);
    await _sendPacketToPeers(
      MeshPacket(
        type: MeshPacketType.messageEdit,
        payload: {'id': messageId, 'body': newBody},
      ),
    );
    notifyListeners();
  }

  /// Delete a local message and propagate the deletion to all connected peers
  Future<void> broadcastDelete(String messageId) async {
    await StorageService.deleteMessage(messageId);
    await _sendPacketToPeers(
      MeshPacket(
        type: MeshPacketType.messageDelete,
        payload: {'id': messageId},
      ),
    );
    notifyListeners();
  }

  void _handleIncomingEdit(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    final body = data['body'] as String?;
    if (id != null && body != null) {
      StorageService.editMessage(id, body);
      notifyListeners();
    }
  }

  void _handleIncomingDelete(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    if (id != null) {
      StorageService.deleteMessage(id);
      notifyListeners();
    }
  }

  /// Send a group invite to all connected peers
  Future<void> sendGroupInvite(MeshGroup group) async {
    await _sendPacketToPeers(
      MeshPacket(type: MeshPacketType.groupInvite, payload: group.toMap()),
    );
  }

  /// Send a group invite to a specific peer
  Future<void> sendGroupInviteToPeer(MeshGroup group, String peerId) async {
    final packet = MeshPacket(
      type: MeshPacketType.groupInvite,
      payload: group.toMap(),
    );
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      await Nearby().sendBytesPayload(peerId, bytes);
      debugPrint('[MESH] Sent group invite to $peerId');
    } catch (e) {
      debugPrint('[MESH] Failed to send invite to $peerId: $e');
    }
  }

  // ── Internal: Send packets ───────────────────────────

  Future<void> _sendPacketToPeers(
    MeshPacket packet, {
    String? excludeId,
  }) async {
    final targetIds = _peers.values
        .where((p) => p.isConnected && p.endpointId != excludeId)
        .map((p) => p.endpointId)
        .toList();

    if (targetIds.isEmpty) return;

    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      for (final id in targetIds) {
        await Nearby().sendBytesPayload(id, bytes);
      }
      debugPrint('[MESH] Sent packet to ${targetIds.length} peers');
    } catch (e) {
      debugPrint('[MESH] Failed to send packet: $e');
    }
  }

  // ── Group Utilities ──────────────────────────────────

  /// Generate a random group ID like "MESH_XXXXXX"
  static String generateGroupId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random();
    final suffix = List.generate(
      6,
      (_) => chars[rand.nextInt(chars.length)],
    ).join();
    return 'MESH_$suffix';
  }

  /// Generate a random symmetric key (base64)
  static String generateSymmetricKey() {
    final rand = Random.secure();
    final bytes = List.generate(32, (_) => rand.nextInt(256));
    return base64Encode(bytes);
  }
}
