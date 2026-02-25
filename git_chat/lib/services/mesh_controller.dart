import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import '../models/message.dart';
import '../services/storage_service.dart';

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

/// The core intelligence of the Serverless Mesh.
/// Replaces typical BLE scanning with Google's Nearby Connections (P2P_CLUSTER)
/// which uses Bluetooth, BLE, and Wi-Fi Direct seamlessly.
class MeshController extends ChangeNotifier {
  final Strategy strategy = Strategy.P2P_CLUSTER;

  final Map<String, MeshPeer> _peers = {};
  bool _isAdvertising = false;
  bool _isDiscovering = false;

  final StreamController<ChatMessage> _incomingMessages =
      StreamController<ChatMessage>.broadcast();

  final Set<String> _seenMessageIds = {};

  // ── Getters ──────────────────────────────────────────
  List<MeshPeer> get connectedPeers =>
      _peers.values.where((p) => p.isConnected).toList();
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  Stream<ChatMessage> get incomingMessages => _incomingMessages.stream;

  // ── Lifecycle ────────────────────────────────────────

  @override
  void dispose() {
    stopMesh();
    _incomingMessages.close();
    super.dispose();
  }

  // ── Mesh Activation ──────────────────────────────────

  /// Starts the "Vibe Coding" Dual Loop: Advertising & Discovering
  /// simultaneously to build the interconnected cluster.
  Future<void> startMesh() async {
    final username = StorageService.getUsername() ?? 'anon';

    // Start Beacon (Advertising)
    try {
      _isAdvertising = await Nearby().startAdvertising(
        username,
        strategy,
        onConnectionInitiated: _onConnectionInit,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
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
            '[MESH] Found peer: $name ($id). Requesting connection...',
          );
          // Auto-connect to build the mesh faster
          await Nearby().requestConnection(
            username,
            id,
            onConnectionInitiated: _onConnectionInit,
            onConnectionResult: _onConnectionResult,
            onDisconnected: _onDisconnected,
          );
        },
        onEndpointLost: (id) {
          debugPrint('[MESH] Lost peer from radar: $id');
        },
      );
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
    // Automatically accept the connection to form the decentralized cluster
    await Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) {
        if (payload.type == PayloadType.BYTES) {
          _handleIncomingBytes(payload.bytes!, endpointId);
        }
      },
      onPayloadTransferUpdate: (endpointId, payloadTransferUpdate) {},
    );
  }

  void _onConnectionResult(String id, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('[MESH] Connected to peer: $id!');
      _peers[id] = MeshPeer(
        endpointId: id,
        endpointName: 'peer',
        isConnected: true,
      );
      notifyListeners();
    } else {
      debugPrint('[MESH] Connection failed or rejected: $id');
      _peers.remove(id);
    }
  }

  void _onDisconnected(String id) {
    debugPrint('[MESH] Disconnected from peer: $id');
    _peers[id]?.isConnected = false;
    _peers.remove(id);
    notifyListeners();
  }

  // ── Gossip Protocol (Messaging & Relay) ──────────────

  /// Send a message originating from this device
  Future<void> broadcastLocalMessage(ChatMessage message) async {
    // 1. Mark as seen so we don't relay our own echo
    _seenMessageIds.add(message.id);

    // 2. Save locally
    StorageService.saveMessage(message);

    // 3. Blast to all immediately connected peers
    await _blastToPeers(message);
  }

  /// Handles incoming payloads from the network
  void _handleIncomingBytes(Uint8List bytes, String sourceId) {
    try {
      final jsonStr = utf8.decode(bytes);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final message = ChatMessage.fromMap(map);

      // --- 1. Deduplication Check ---
      if (_seenMessageIds.contains(message.id)) {
        debugPrint(
          '[MESH] Dropping duplicate from $sourceId: ${message.id.substring(0, 6)}',
        );
        return;
      }
      _seenMessageIds.add(message.id);

      debugPrint('[MESH] Received new msg from $sourceId: ${message.body}');

      // --- 2. Check Group / Delivery Logic ---
      final myUsername = StorageService.getUsername() ?? 'anon';
      bool isForMe = (message.to == myUsername || message.to == 'broadcast');

      // TODO: Future Group Encryption Logic goes here.
      // If we are part of the groupId, we decrypt and store.

      if (isForMe) {
        StorageService.saveMessage(message);
        _incomingMessages.add(message);
      }

      // --- 3. Relay Logic (The Gossip hops) ---
      if (message.ttl > 0) {
        // Decrement TTL
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
        _blastToPeers(relayMsg, excludeId: sourceId);
      } else {
        debugPrint('[MESH] Message died (TTL=0)');
      }
    } catch (e) {
      debugPrint('[MESH] Failed to parse payload from $sourceId: $e');
    }
  }

  /// Sends a raw message map to all known connected endpoints, optionally excluding the sender
  Future<void> _blastToPeers(ChatMessage message, {String? excludeId}) async {
    final targetIds = _peers.values
        .where((p) => p.isConnected && p.endpointId != excludeId)
        .map((p) => p.endpointId)
        .toList();

    if (targetIds.isEmpty) return;

    try {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(message.toMap())),
      );
      for (final id in targetIds) {
        await Nearby().sendBytesPayload(id, bytes);
      }
      debugPrint('[MESH] Blasted message to ${targetIds.length} peers');
    } catch (e) {
      debugPrint('[MESH] Failed to blast bytes: $e');
    }
  }
}
