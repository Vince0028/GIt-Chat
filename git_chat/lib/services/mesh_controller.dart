import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/group.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../services/tower_service.dart';

/// Represents a peer connected via Nearby Connections API
class MeshPeer {
  final String endpointId;
  String endpointName;
  bool isConnected;
  DateTime lastSeen;
  String? deviceModel;       // e.g. "Samsung Galaxy S21"
  int? lastRttMs;            // round-trip time in milliseconds
  String? estimatedDistance;  // human-readable distance label

  MeshPeer({
    required this.endpointId,
    required this.endpointName,
    this.isConnected = false,
    this.deviceModel,
  }) : lastSeen = DateTime.now();
}

/// Packet types for the mesh protocol
enum MeshPacketType {
  message,
  groupInvite,
  groupJoinAck,
  messageEdit,
  messageDelete,
  imageMetadata,
  imageChunk,
  callOffer,
  callAnswer,
  iceCandidate,
  callEnd,
  syncRequest,   // "Here are the message IDs I have — what am I missing?"
  syncResponse,  // "Here are the messages you're missing"
  peerInfo,      // Device model + metadata exchange after connect
  ping,          // RTT measurement request
  pong,          // RTT measurement response
  clearMessages, // Clear all messages in a group or global chat
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

  // Arduino Signal Tower (optional BLE relay)
  final TowerService towerService = TowerService();
  StreamSubscription<String>? _towerMsgSub;

  // Preserved endpoint names from _onConnectionInit (fixes 'peer' fallback bug)
  final Map<String, String> _endpointNames = {};

  // Ping/pong for RTT-based distance estimation
  Timer? _pingTimer;
  final Map<String, int> _pendingPings = {}; // endpointId -> sentTimestamp

  // Cached device model string
  String? _localDeviceModel;

  // Connection retry settings
  static const int _maxConnectionRetries = 7;
  static const int _baseRetryDelayMs = 1000; // 1 second base, doubles each retry
  final Map<String, int> _connectionAttempts = {}; // endpointId -> attempt count

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

  // Pending group invites (received but not yet joined)
  final Map<String, MeshGroup> _pendingGroupInvites = {};

  // Track peers we've already synced with to avoid duplicate sync storms
  final Set<String> _syncedPeers = {};

  // Max messages to send in a single sync response (prevent BLE overload)
  static const int _maxSyncBatch = 50;

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
  Map<String, MeshGroup> get pendingGroupInvites =>
      Map.unmodifiable(_pendingGroupInvites);

  // Call signaling
  final StreamController<Map<String, dynamic>> _incomingCallSignals =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCallSignals =>
      _incomingCallSignals.stream;

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
    _pingTimer?.cancel();
    _towerMsgSub?.cancel();
    towerService.dispose();
    stopMesh();
    _incomingMessages.close();
    _incomingGroupInvites.close();
    _passwordProtectedInvites.close();
    _incomingCallSignals.close();
    super.dispose();
  }

  /// Fetch device model once and cache it
  Future<String> _getDeviceModel() async {
    if (_localDeviceModel != null) return _localDeviceModel!;
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        _localDeviceModel = '${info.brand} ${info.model}';
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        _localDeviceModel = info.utsname.machine;
      } else {
        _localDeviceModel = Platform.operatingSystem;
      }
    } catch (_) {
      _localDeviceModel = 'Unknown';
    }
    return _localDeviceModel!;
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
            '[MESH] Found peer: $name ($id). Attempting connection...',
          );

          if (_peers.containsKey(id) && _peers[id]!.isConnected) return;

          // Reset attempt counter for newly found peer
          _connectionAttempts[id] = 0;
          await _attemptConnectionWithRetry(username, id, name);
        },
        onEndpointLost: (id) {
          debugPrint('[MESH] Lost peer from radar: $id');
          _connectionAttempts.remove(id);
        },
        serviceId: _serviceId,
      );
      debugPrint('[MESH] Discovery started: $_isDiscovering');
    } catch (e) {
      debugPrint('[MESH] Discovery failed: $e');
    }

    notifyListeners();

    // Start Arduino tower scan (optional — mesh works without it)
    _startTowerService();
  }

  /// Start the BLE tower scanner and wire up message relay
  void _startTowerService() {
    _towerMsgSub?.cancel();
    _towerMsgSub = towerService.incomingTowerMessages.listen((jsonStr) {
      debugPrint('[MESH] Tower relayed message received');
      try {
        final bytes = Uint8List.fromList(utf8.encode(jsonStr));
        _handleIncomingPayload(bytes, 'tower');
      } catch (e) {
        debugPrint('[MESH] Failed to handle tower message: $e');
      }
    });
    towerService.addListener(_onTowerUpdate);
    towerService.startScan();
  }

  void _onTowerUpdate() {
    notifyListeners(); // propagate tower state changes to UI
  }

  void stopMesh() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _towerMsgSub?.cancel();
    towerService.removeListener(_onTowerUpdate);
    towerService.stop();
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    _isAdvertising = false;
    _isDiscovering = false;
    _peers.clear();
    _endpointNames.clear();
    _syncedPeers.clear();
    _connectionAttempts.clear();
    _pendingPings.clear();
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
    // Preserve the endpoint name for use in _onConnectionResult
    _endpointNames[id] = info.endpointName;

    // Only create a new peer entry if _onConnectionResult hasn't already done so.
    // This avoids overwriting isConnected=true with a stale false value.
    if (!_peers.containsKey(id)) {
      _peers[id] = MeshPeer(endpointId: id, endpointName: info.endpointName);
    } else {
      _peers[id]!.endpointName = info.endpointName;
      _peers[id]!.lastSeen = DateTime.now();
    }
  }

  void _onConnectionResult(String id, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('[MESH] Connected to peer: $id!');
      // Use preserved name from _onConnectionInit, fall back to stored username
      final name = _endpointNames[id] ?? 'peer';
      if (_peers.containsKey(id)) {
        _peers[id]!.isConnected = true;
        _peers[id]!.lastSeen = DateTime.now();
        // Fix: ensure name is never 'peer' if we have a real name
        if (_peers[id]!.endpointName == 'peer' && name != 'peer') {
          _peers[id]!.endpointName = name;
        }
      } else {
        _peers[id] = MeshPeer(
          endpointId: id,
          endpointName: name,
          isConnected: true,
        );
      }
      notifyListeners();

      // ── Send our device info to the new peer ──
      _sendPeerInfo(id);

      // ── Start ping timer if not running ──
      _startPingTimer();

      // ── Sync-on-Connect: request message history from this peer ──
      _requestSyncFromPeer(id);
    } else {
      debugPrint('[MESH] Connection failed or rejected: $id');
      _peers.remove(id);
      _endpointNames.remove(id);
      notifyListeners();
    }
  }

  void _onDisconnected(String id) {
    debugPrint('[MESH] Disconnected from peer: $id');
    _peers.remove(id);
    _endpointNames.remove(id);
    _syncedPeers.remove(id);
    _connectionAttempts.remove(id);
    _pendingPings.remove(id);
    // Stop ping timer if no connected peers left
    if (connectedPeers.isEmpty) {
      _pingTimer?.cancel();
      _pingTimer = null;
    }
    notifyListeners();
  }

  // ── Connection Retry with Exponential Backoff ────────

  /// Attempts to connect to a peer with up to [_maxConnectionRetries] retries.
  /// Uses exponential backoff + random jitter to handle long-range discovery
  /// and avoid P2P_CLUSTER simultaneous connection collisions.
  Future<void> _attemptConnectionWithRetry(
    String username,
    String endpointId,
    String endpointName,
  ) async {
    for (int attempt = 1; attempt <= _maxConnectionRetries; attempt++) {
      // If already connected (maybe via the other device's request), stop
      if (_peers.containsKey(endpointId) && _peers[endpointId]!.isConnected) {
        debugPrint('[MESH] Peer $endpointId already connected, skipping retry');
        _connectionAttempts.remove(endpointId);
        return;
      }

      // If peer was lost from radar or mesh stopped, abort
      if (!_isDiscovering && !_isAdvertising) return;

      // Exponential backoff: 1s, 2s, 4s, 8s... + random jitter (0-1.5s)
      final backoff = _baseRetryDelayMs * (1 << (attempt - 1));
      final jitter = Random().nextInt(1500);
      final delay = backoff + jitter;

      debugPrint(
        '[MESH] Connection attempt $attempt/$_maxConnectionRetries '
        'to $endpointName ($endpointId) — waiting ${delay}ms...',
      );

      await Future.delayed(Duration(milliseconds: delay));

      // Double-check connection status after the delay
      if (_peers.containsKey(endpointId) && _peers[endpointId]!.isConnected) {
        _connectionAttempts.remove(endpointId);
        return;
      }

      try {
        _connectionAttempts[endpointId] = attempt;
        await Nearby().requestConnection(
          username,
          endpointId,
          onConnectionInitiated: _onConnectionInit,
          onConnectionResult: _onConnectionResult,
          onDisconnected: _onDisconnected,
        );
        // If requestConnection didn't throw, the handshake started successfully
        debugPrint(
          '[MESH] ✅ Connection request accepted on attempt $attempt',
        );
        _connectionAttempts.remove(endpointId);
        return;
      } catch (e) {
        debugPrint(
          '[MESH] ❌ Attempt $attempt/$_maxConnectionRetries failed: $e',
        );
        if (attempt == _maxConnectionRetries) {
          debugPrint(
            '[MESH] Gave up connecting to $endpointName after '
            '$_maxConnectionRetries attempts',
          );
          _connectionAttempts.remove(endpointId);
        }
      }
    }
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
          case MeshPacketType.callOffer:
          case MeshPacketType.callAnswer:
          case MeshPacketType.iceCandidate:
          case MeshPacketType.callEnd:
            // Ignore own call signals that bounced back via mesh/tower
            final signalFrom = packet.payload['from'] as String? ?? '';
            final myName = StorageService.getUsername() ?? '';
            if (signalFrom.isNotEmpty && signalFrom == myName) {
              debugPrint('[MESH] Ignoring own call signal ($signalFrom)');
              break;
            }
            packet.payload['signalType'] = packet.type.name;
            packet.payload['sourceId'] = sourceId;
            _incomingCallSignals.add(packet.payload);
            break;
          case MeshPacketType.syncRequest:
            _handleSyncRequest(packet.payload, sourceId);
            break;
          case MeshPacketType.syncResponse:
            _handleSyncResponse(packet.payload, sourceId);
            break;
          case MeshPacketType.peerInfo:
            _handlePeerInfo(packet.payload, sourceId);
            break;
          case MeshPacketType.ping:
            _handlePing(packet.payload, sourceId);
            break;
          case MeshPacketType.pong:
            _handlePong(packet.payload, sourceId);
            break;
          case MeshPacketType.clearMessages:
            _handleClearMessages(packet.payload, sourceId);
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

    // Store as pending invite — user must manually join via Group ID + Password
    _pendingGroupInvites[group.id] = group;
    debugPrint(
      '[MESH] Stored pending invite for "${group.name}" (ID: ${group.id})',
    );
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

  /// Attempt to join a group using Group ID and password.
  /// Returns: 'success', 'not_found', or 'wrong_password'
  Future<String> joinGroupWithCredentials(String groupId, String password) async {
    final group = _pendingGroupInvites[groupId];
    if (group == null) return 'not_found';

    // Check password if group has one
    if (group.password != null && group.password!.isNotEmpty) {
      if (password != group.password) return 'wrong_password';
    }

    // Join the group
    final username = StorageService.getUsername() ?? 'anon';
    if (!group.members.contains(username)) {
      group.members.add(username);
    }
    StorageService.saveGroup(group);
    _pendingGroupInvites.remove(groupId);
    notifyListeners();

    // Broadcast join acknowledgment so other peers update their member lists
    await _sendPacketToPeers(
      MeshPacket(
        type: MeshPacketType.groupJoinAck,
        payload: {'groupId': groupId, 'username': username},
      ),
    );

    // Request past chat history for this group from connected peers
    await requestGroupSync(groupId);

    return 'success';
  }

  // ── Public API: Call Signaling ───────────────────────

  /// Send a call signal (offer/answer/ice/end) to all connected peers
  Future<void> sendCallSignal(
    MeshPacketType type,
    Map<String, dynamic> data,
  ) async {
    // Stamp with sender username so receivers can ignore self-echoes
    data['from'] = StorageService.getUsername() ?? 'anon';
    await _sendPacketToPeers(MeshPacket(type: type, payload: data));
  }

  // ── Public API: Send Messages ────────────────────────

  /// Broadcast a "clear all messages" command to all peers
  Future<void> broadcastClearMessages({String? groupId}) async {
    await _sendPacketToPeers(
      MeshPacket(
        type: MeshPacketType.clearMessages,
        payload: {'groupId': groupId ?? ''},
      ),
    );
    debugPrint('[MESH] Broadcasted clearMessages (group=${groupId ?? 'global'})');
  }

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

    if (targetIds.isEmpty && !towerService.isConnected) return;

    try {
      final jsonStr = jsonEncode(packet.toMap());
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      for (final id in targetIds) {
        await Nearby().sendBytesPayload(id, bytes);
      }
      if (targetIds.isNotEmpty) {
        debugPrint('[MESH] Sent packet to ${targetIds.length} peers');
      }

      // Also relay through Arduino tower if connected (text messages & invites)
      if (towerService.isConnected &&
          (packet.type == MeshPacketType.message ||
           packet.type == MeshPacketType.groupInvite ||
           packet.type == MeshPacketType.groupJoinAck)) {
        towerService.sendMessage(jsonStr);
      }
    } catch (e) {
      debugPrint('[MESH] Failed to send packet: $e');
    }
  }

  // ── Gossip Protocol: Sync-on-Connect ─────────────────

  /// Send a sync request to a newly connected peer.
  /// Includes all our message IDs + group membership so they know what to send.
  Future<void> _requestSyncFromPeer(String peerId) async {
    if (_syncedPeers.contains(peerId)) return;
    _syncedPeers.add(peerId);

    // Gather all text message IDs we already have
    final allMessages = StorageService.getMessages(); // global/broadcast
    final groups = StorageService.getGroups();
    final myMessageIds = <String>{};

    for (final m in allMessages) {
      myMessageIds.add(m.id);
    }
    for (final g in groups) {
      final groupMsgs = StorageService.getMessages(groupId: g.id);
      for (final m in groupMsgs) {
        myMessageIds.add(m.id);
      }
    }

    final myGroupIds = groups.map((g) => g.id).toList();

    final payload = {
      'messageIds': myMessageIds.toList(),
      'groupIds': myGroupIds,
    };

    debugPrint(
      '[SYNC] Requesting sync from $peerId '
      '(I have ${myMessageIds.length} msgs, ${myGroupIds.length} groups)',
    );

    try {
      final packet = MeshPacket(
        type: MeshPacketType.syncRequest,
        payload: payload,
      );
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      await Nearby().sendBytesPayload(peerId, bytes);
    } catch (e) {
      debugPrint('[SYNC] Failed to send sync request to $peerId: $e');
    }
  }

  /// Handle an incoming sync request from a peer.
  /// Compare their message IDs against ours and send back what they're missing.
  void _handleSyncRequest(
    Map<String, dynamic> data,
    String sourceId,
  ) async {
    final theirMessageIds = Set<String>.from(
      (data['messageIds'] as List?)?.cast<String>() ?? [],
    );
    final theirGroupIds = Set<String>.from(
      (data['groupIds'] as List?)?.cast<String>() ?? [],
    );

    debugPrint(
      '[SYNC] Peer $sourceId has ${theirMessageIds.length} msgs, '
      '${theirGroupIds.length} groups',
    );

    // ── 1) Find text messages they're missing (global + groups) ──
    final missingMessages = <Map<String, dynamic>>[];

    // Global/broadcast messages
    final globalMsgs = StorageService.getMessages();
    for (final m in globalMsgs) {
      if (!theirMessageIds.contains(m.id) &&
          !m.isDeleted &&
          m.messageType == 'text') {
        missingMessages.add(m.toMap());
        if (missingMessages.length >= _maxSyncBatch) break;
      }
    }

    // Group messages — only from groups the peer is also a member of
    if (missingMessages.length < _maxSyncBatch) {
      final myGroups = StorageService.getGroups();
      for (final g in myGroups) {
        if (!theirGroupIds.contains(g.id)) continue; // they're not in this group
        final groupMsgs = StorageService.getMessages(groupId: g.id);
        for (final m in groupMsgs) {
          if (!theirMessageIds.contains(m.id) &&
              !m.isDeleted &&
              m.messageType == 'text') {
            missingMessages.add(m.toMap());
            if (missingMessages.length >= _maxSyncBatch) break;
          }
        }
        if (missingMessages.length >= _maxSyncBatch) break;
      }
    }

    // ── 2) Find group invites they might not have yet ──
    final missingGroups = <Map<String, dynamic>>[];
    final myGroups = StorageService.getGroups();
    for (final g in myGroups) {
      if (!theirGroupIds.contains(g.id)) {
        // They don't have this group — send invite so they can join via ID+password
        missingGroups.add(g.toMap());
      }
    }

    debugPrint(
      '[SYNC] Sending ${missingMessages.length} msgs + '
      '${missingGroups.length} group invites to $sourceId',
    );

    if (missingMessages.isEmpty && missingGroups.isEmpty) return;

    // Send sync response
    final responsePayload = {
      'messages': missingMessages,
      'groups': missingGroups,
    };

    try {
      final packet = MeshPacket(
        type: MeshPacketType.syncResponse,
        payload: responsePayload,
      );
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      await Nearby().sendBytesPayload(sourceId, bytes);
    } catch (e) {
      debugPrint('[SYNC] Failed to send sync response to $sourceId: $e');
    }

    // Also send our own sync request back (bidirectional sync)
    _requestSyncFromPeer(sourceId);
  }

  /// Handle an incoming sync response — save the messages we were missing.
  void _handleSyncResponse(
    Map<String, dynamic> data,
    String sourceId,
  ) {
    final messagesList = data['messages'] as List? ?? [];
    final groupsList = data['groups'] as List? ?? [];

    int savedMsgs = 0;
    int savedGroups = 0;

    // ── Process incoming group invites (store as pending) ──
    for (final gMap in groupsList) {
      try {
        final group = MeshGroup.fromMap(Map<String, dynamic>.from(gMap as Map));
        if (!StorageService.isGroupMember(group.id) &&
            !_pendingGroupInvites.containsKey(group.id)) {
          _pendingGroupInvites[group.id] = group;
          savedGroups++;
        }
      } catch (e) {
        debugPrint('[SYNC] Failed to parse group: $e');
      }
    }

    // ── Process incoming messages ──
    for (final mMap in messagesList) {
      try {
        final msg = ChatMessage.fromMap(Map<String, dynamic>.from(mMap as Map));

        // Skip if we already have it
        if (StorageService.hasMessage(msg.id)) continue;
        if (_seenMessageIds.contains(msg.id)) continue;

        _seenMessageIds.add(msg.id);

        // Check if this message is for us
        final myUsername = StorageService.getUsername() ?? 'anon';
        bool isForMe = false;

        if (msg.groupId != null && msg.groupId!.isNotEmpty) {
          isForMe = StorageService.isGroupMember(msg.groupId!);
        } else {
          isForMe = (msg.to == myUsername || msg.to == 'broadcast');
        }

        if (isForMe) {
          StorageService.saveMessage(msg);
          _incomingMessages.add(msg);
          savedMsgs++;
        }
      } catch (e) {
        debugPrint('[SYNC] Failed to parse message: $e');
      }
    }

    if (savedMsgs > 0 || savedGroups > 0) {
      debugPrint(
        '[SYNC] ✅ Synced $savedMsgs messages + $savedGroups groups from $sourceId',
      );
      notifyListeners();
    }
  }

  /// Request sync for a specific group's history from all connected peers.
  /// Called after a user joins a group via ID+password.
  Future<void> requestGroupSync(String groupId) async {
    final allMessages = StorageService.getMessages(groupId: groupId);
    final myMessageIds = allMessages.map((m) => m.id).toList();
    final myGroupIds = StorageService.getGroups().map((g) => g.id).toList();

    final payload = {
      'messageIds': myMessageIds,
      'groupIds': myGroupIds,
    };

    debugPrint(
      '[SYNC] Requesting group sync for $groupId '
      '(I have ${myMessageIds.length} msgs in this group)',
    );

    await _sendPacketToPeers(
      MeshPacket(type: MeshPacketType.syncRequest, payload: payload),
    );
  }

  // ── Peer Info Exchange ────────────────────────────────

  /// Send our device info to a specific peer right after connecting
  Future<void> _sendPeerInfo(String peerId) async {
    final model = await _getDeviceModel();
    final username = StorageService.getUsername() ?? 'anon';
    final packet = MeshPacket(
      type: MeshPacketType.peerInfo,
      payload: {
        'username': username,
        'deviceModel': model,
      },
    );
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      await Nearby().sendBytesPayload(peerId, bytes);
      debugPrint('[MESH] Sent peerInfo to $peerId (model=$model)');
    } catch (e) {
      debugPrint('[MESH] Failed to send peerInfo to $peerId: $e');
    }
  }

  /// Handle an incoming peerInfo packet — update peer's device model & name
  void _handlePeerInfo(Map<String, dynamic> data, String sourceId) {
    final model = data['deviceModel'] as String?;
    final username = data['username'] as String?;
    if (_peers.containsKey(sourceId)) {
      if (model != null) _peers[sourceId]!.deviceModel = model;
      if (username != null && username.isNotEmpty) {
        _peers[sourceId]!.endpointName = username;
      }
      debugPrint('[MESH] Got peerInfo from $sourceId: model=$model user=$username');
      notifyListeners();
    }
  }

  // ── Ping / Pong — RTT-based distance estimation ─────

  /// Start the periodic ping timer (every 3 seconds)
  void _startPingTimer() {
    if (_pingTimer != null) return; // already running
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _sendPingToAllPeers();
    });
    // Send first ping immediately
    _sendPingToAllPeers();
  }

  /// Send a ping to all connected peers
  void _sendPingToAllPeers() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final packet = MeshPacket(
      type: MeshPacketType.ping,
      payload: {'ts': now},
    );
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      for (final peer in connectedPeers) {
        _pendingPings[peer.endpointId] = now;
        Nearby().sendBytesPayload(peer.endpointId, bytes);
      }
    } catch (e) {
      debugPrint('[MESH] Ping failed: $e');
    }
  }

  /// Handle an incoming ping — echo it back as a pong
  void _handlePing(Map<String, dynamic> data, String sourceId) {
    final packet = MeshPacket(
      type: MeshPacketType.pong,
      payload: {'ts': data['ts']},
    );
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toMap())));
      Nearby().sendBytesPayload(sourceId, bytes);
    } catch (e) {
      debugPrint('[MESH] Pong reply failed: $e');
    }
  }

  /// Handle an incoming pong — calculate RTT and estimate distance
  void _handlePong(Map<String, dynamic> data, String sourceId) {
    final sentTs = data['ts'] as int?;
    if (sentTs == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final rtt = now - sentTs;
    _pendingPings.remove(sourceId);

    if (_peers.containsKey(sourceId)) {
      _peers[sourceId]!.lastRttMs = rtt;
      _peers[sourceId]!.estimatedDistance = _rttToDistance(rtt);
      _peers[sourceId]!.lastSeen = DateTime.now();
      notifyListeners();
    }
  }

  /// Convert RTT (ms) to a human-readable distance estimate.
  /// Nearby Connections adds heavy protocol overhead (BLE stack, JNI,
  /// serialisation) so even point-blank RTT is typically 100-300 ms.
  String _rttToDistance(int rttMs) {
    if (rttMs < 200) return '~1-2m (very close)';
    if (rttMs < 400) return '~3-5m (nearby)';
    if (rttMs < 700) return '~5-10m (close)';
    if (rttMs < 1200) return '~10-20m (moderate)';
    if (rttMs < 2000) return '~20-30m (far)';
    return '~30m+ (very far)';
  }

  /// Handle incoming "clear all messages" from a peer
  void _handleClearMessages(Map<String, dynamic> data, String sourceId) {
    final groupId = data['groupId'] as String? ?? '';
    debugPrint('[MESH] Received clearMessages from $sourceId (group=$groupId)');

    if (groupId.isNotEmpty) {
      StorageService.clearGroupMessages(groupId);
    } else {
      StorageService.clearBroadcastMessages();
    }

    // Notify UI to refresh
    _incomingMessages.add(ChatMessage(
      id: 'clear_${DateTime.now().millisecondsSinceEpoch}',
      from: 'system',
      to: 'broadcast',
      body: '',
      timestamp: DateTime.now(),
      groupId: groupId.isNotEmpty ? groupId : null,
    ));
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
