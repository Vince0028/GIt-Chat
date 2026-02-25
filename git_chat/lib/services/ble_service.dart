import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/message.dart';
import '../services/storage_service.dart';

/// Custom BLE Service UUID for BitChat discovery
const String kBitChatServiceUuid = '12345678-1234-5678-1234-56789abcdef0';

/// Characteristic UUID for sending/receiving messages
const String kMessageCharUuid = '12345678-1234-5678-1234-56789abcdef1';

/// Characteristic UUID for exchanging usernames
const String kUsernameCharUuid = '12345678-1234-5678-1234-56789abcdef2';

/// Represents a discovered peer
class BLEPeer {
  final String deviceId;
  final String deviceName;
  String? username;
  int rssi;
  BluetoothDevice? device;
  BluetoothCharacteristic? messageChar;
  BluetoothCharacteristic? usernameChar;
  bool isConnected;
  DateTime lastSeen;

  BLEPeer({
    required this.deviceId,
    required this.deviceName,
    this.username,
    this.rssi = 0,
    this.device,
    this.messageChar,
    this.usernameChar,
    this.isConnected = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();
}

class BLEService extends ChangeNotifier {
  // ── State ────────────────────────────────────────────
  final Map<String, BLEPeer> _peers = {};
  bool _isScanning = false;
  final bool _isAdvertising = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  final StreamController<ChatMessage> _incomingMessages =
      StreamController<ChatMessage>.broadcast();

  // ── Getters ──────────────────────────────────────────
  List<BLEPeer> get peers => _peers.values.toList();
  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;
  BluetoothAdapterState get adapterState => _adapterState;
  Stream<ChatMessage> get incomingMessages => _incomingMessages.stream;
  int get connectedPeerCount =>
      _peers.values.where((p) => p.isConnected).length;

  // ── Lifecycle ────────────────────────────────────────

  BLEService() {
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      _adapterState = state;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    stopScan();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    _incomingMessages.close();
    super.dispose();
  }

  // ── Scanning ─────────────────────────────────────────

  Future<void> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_isScanning) return;

    _isScanning = true;
    notifyListeners();

    // Clear stale peers (older than 60 seconds)
    _peers.removeWhere(
      (_, p) => DateTime.now().difference(p.lastSeen).inSeconds > 60,
    );

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(kBitChatServiceUuid)],
        timeout: timeout,
        androidUsesFineLocation: true,
      );

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final id = r.device.remoteId.str;
          if (_peers.containsKey(id)) {
            _peers[id]!.rssi = r.rssi;
            _peers[id]!.lastSeen = DateTime.now();
          } else {
            _peers[id] = BLEPeer(
              deviceId: id,
              deviceName: r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : 'Unknown',
              rssi: r.rssi,
              device: r.device,
            );
          }
        }
        notifyListeners();
      });
    } catch (e) {
      debugPrint('BLE Scan error: $e');
    }

    // Auto-stop after timeout
    Future.delayed(timeout, () {
      if (_isScanning) stopScan();
    });
  }

  void stopScan() {
    FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    _isScanning = false;
    notifyListeners();
  }

  // ── Connection ───────────────────────────────────────

  Future<bool> connectToPeer(String deviceId) async {
    final peer = _peers[deviceId];
    if (peer == null || peer.device == null) return false;

    try {
      await peer.device!.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
      );

      // Discover services
      final services = await peer.device!.discoverServices();
      for (final service in services) {
        if (service.uuid.str.toLowerCase() == kBitChatServiceUuid) {
          for (final char in service.characteristics) {
            final charUuid = char.uuid.str.toLowerCase();
            if (charUuid == kMessageCharUuid) {
              peer.messageChar = char;
              // Subscribe to incoming messages
              await char.setNotifyValue(true);
              char.onValueReceived.listen((value) {
                _handleIncomingMessage(value, peer);
              });
            } else if (charUuid == kUsernameCharUuid) {
              peer.usernameChar = char;
              // Read peer's username
              final nameBytes = await char.read();
              if (nameBytes.isNotEmpty) {
                peer.username = utf8.decode(nameBytes);
              }
              // Write our username
              final myName = StorageService.getUsername() ?? 'anon';
              await char.write(utf8.encode(myName));
            }
          }
        }
      }

      peer.isConnected = true;
      notifyListeners();

      // Listen for disconnection
      peer.device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          peer.isConnected = false;
          peer.messageChar = null;
          peer.usernameChar = null;
          notifyListeners();
        }
      });

      return true;
    } catch (e) {
      debugPrint('BLE Connect error: $e');
      return false;
    }
  }

  Future<void> disconnectFromPeer(String deviceId) async {
    final peer = _peers[deviceId];
    if (peer?.device == null) return;

    try {
      await peer!.device!.disconnect();
      peer.isConnected = false;
      peer.messageChar = null;
      peer.usernameChar = null;
      notifyListeners();
    } catch (e) {
      debugPrint('BLE Disconnect error: $e');
    }
  }

  // ── Messaging ────────────────────────────────────────

  Future<bool> sendMessage(ChatMessage message, String peerDeviceId) async {
    final peer = _peers[peerDeviceId];
    if (peer == null || !peer.isConnected || peer.messageChar == null) {
      return false;
    }

    try {
      final jsonStr = jsonEncode(message.toMap());
      final bytes = utf8.encode(jsonStr);

      // BLE has a ~512 byte MTU typically; split if needed
      await peer.messageChar!.write(
        Uint8List.fromList(bytes),
        withoutResponse: false,
      );

      // Save to local storage
      StorageService.saveMessage(message);
      return true;
    } catch (e) {
      debugPrint('BLE Send error: $e');
      return false;
    }
  }

  /// Broadcast a message to all connected peers
  Future<void> broadcastMessage(ChatMessage message) async {
    StorageService.saveMessage(message);

    for (final peer in _peers.values) {
      if (peer.isConnected && peer.messageChar != null) {
        try {
          final jsonStr = jsonEncode(message.toMap());
          final bytes = utf8.encode(jsonStr);
          await peer.messageChar!.write(
            Uint8List.fromList(bytes),
            withoutResponse: false,
          );
        } catch (e) {
          debugPrint('BLE Broadcast to ${peer.deviceId} error: $e');
        }
      }
    }
  }

  // ── Internal ─────────────────────────────────────────

  void _handleIncomingMessage(List<int> value, BLEPeer fromPeer) {
    try {
      final jsonStr = utf8.decode(value);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final message = ChatMessage.fromMap(map);

      // Don't save duplicates
      if (!StorageService.hasMessage(message.id)) {
        StorageService.saveMessage(message);
        _incomingMessages.add(message);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('BLE Parse message error: $e');
    }
  }
}
