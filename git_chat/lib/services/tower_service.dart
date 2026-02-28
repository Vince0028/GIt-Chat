import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Connection state of the Arduino Signal Tower
enum TowerState { disconnected, scanning, connecting, connected }

/// Manages BLE connection to the GitChat Arduino Signal Tower.
///
/// The tower is an optional relay — the mesh works fine without it.
/// When present it receives chat messages from phones and re-broadcasts
/// them via BLE notifications so phones out of direct Nearby Connections
/// range can still receive messages.
///
/// Tower protocol (matches gitchat_tower.ino):
///   Service  19B10000-E8F2-537E-4F6C-D104768A1214
///   MSG_CHAR 19B10001-...  Read|Write|Notify  — chat JSON
///   PEER_CHAR 19B10002-... Read|Notify         — peer count (uint8)
///   CMD_CHAR  19B10003-... Write               — commands
class TowerService extends ChangeNotifier {
  // ── BLE UUIDs (must match Arduino sketch) ────────────
  static final Guid _serviceUuid =
      Guid('19B10000-E8F2-537E-4F6C-D104768A1214');
  static final Guid _msgCharUuid =
      Guid('19B10001-E8F2-537E-4F6C-D104768A1214');
  static final Guid _peerCharUuid =
      Guid('19B10002-E8F2-537E-4F6C-D104768A1214');
  static final Guid _cmdCharUuid =
      Guid('19B10003-E8F2-537E-4F6C-D104768A1214');

  static const String _towerNamePrefix = 'GITCHAT-TOWER';
  static const Duration _scanTimeout = Duration(seconds: 10);
  static const Duration _reconnectDelay = Duration(seconds: 5);

  // ── State ────────────────────────────────────────────
  TowerState _state = TowerState.disconnected;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _msgChar;
  BluetoothCharacteristic? _peerChar;
  BluetoothCharacteristic? _cmdChar;
  int _towerPeerCount = 0;
  String _towerName = '';
  bool _autoReconnect = true;
  Timer? _reconnectTimer;

  StreamSubscription? _scanSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _msgNotifySub;
  StreamSubscription? _peerNotifySub;

  /// Incoming messages relayed through the tower
  final StreamController<String> _incomingTowerMessages =
      StreamController<String>.broadcast();

  // ── Getters ──────────────────────────────────────────
  TowerState get state => _state;
  bool get isConnected => _state == TowerState.connected;
  int get towerPeerCount => _towerPeerCount;
  String get towerName => _towerName;
  Stream<String> get incomingTowerMessages => _incomingTowerMessages.stream;

  // ── Lifecycle ────────────────────────────────────────

  /// Start scanning for a GitChat tower. If found, auto-connect.
  Future<void> startScan() async {
    if (_state == TowerState.scanning || _state == TowerState.connected) return;

    _log('Starting BLE scan for tower...');
    _state = TowerState.scanning;
    notifyListeners();

    try {
      // Stop any previous scan
      await FlutterBluePlus.stopScan();

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          if (name.startsWith(_towerNamePrefix)) {
            _log('Found tower: $name (${r.device.remoteId})');
            _towerName = name;
            FlutterBluePlus.stopScan();
            _scanSub?.cancel();
            _connectToDevice(r.device);
            return;
          }
        }
      });

      await FlutterBluePlus.startScan(
        withNames: [_towerNamePrefix],
        timeout: _scanTimeout,
        androidScanMode: AndroidScanMode.lowLatency,
      );

      // If scan finishes without finding tower
      await Future.delayed(_scanTimeout + const Duration(seconds: 1));
      if (_state == TowerState.scanning) {
        _log('Scan complete — no tower found');
        _state = TowerState.disconnected;
        notifyListeners();
        _scheduleReconnect();
      }
    } catch (e) {
      _log('Scan error: $e');
      _state = TowerState.disconnected;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  /// Stop scanning and disconnect from tower
  Future<void> stop() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    await _disconnect();
    _state = TowerState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    _connectionSub?.cancel();
    _msgNotifySub?.cancel();
    _peerNotifySub?.cancel();
    _incomingTowerMessages.close();
    _disconnect();
    super.dispose();
  }

  // ── Connect ──────────────────────────────────────────

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _state = TowerState.connecting;
    notifyListeners();
    _log('Connecting to ${device.platformName}...');

    try {
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 15),
      );
      _device = device;

      // Listen for disconnection
      _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _log('Tower disconnected');
          _onDisconnected();
        }
      });

      // Discover services
      _log('Discovering services...');
      final services = await device.discoverServices();

      BluetoothService? gitChatService;
      for (final s in services) {
        if (s.uuid == _serviceUuid) {
          gitChatService = s;
          break;
        }
      }

      if (gitChatService == null) {
        _log('ERROR: GitChat service not found on device!');
        await _disconnect();
        _scheduleReconnect();
        return;
      }

      // Find characteristics
      for (final c in gitChatService.characteristics) {
        if (c.uuid == _msgCharUuid) _msgChar = c;
        if (c.uuid == _peerCharUuid) _peerChar = c;
        if (c.uuid == _cmdCharUuid) _cmdChar = c;
      }

      if (_msgChar == null) {
        _log('ERROR: MSG characteristic not found!');
        await _disconnect();
        _scheduleReconnect();
        return;
      }

      // Subscribe to message notifications (relay from tower)
      _msgNotifySub?.cancel();
      await _msgChar!.setNotifyValue(true);
      _msgNotifySub = _msgChar!.onValueReceived.listen((bytes) {
        final msg = utf8.decode(bytes);
        if (msg.isNotEmpty && msg != 'TOWER_READY' && msg != 'PONG') {
          // Filter out tower system messages, only relay chat JSON
          if (!msg.startsWith('TOWER:')) {
            _log('Received relay: ${msg.length > 60 ? '${msg.substring(0, 60)}...' : msg}');
            _incomingTowerMessages.add(msg);
          }
        }
      });

      // Subscribe to peer count notifications
      if (_peerChar != null) {
        _peerNotifySub?.cancel();
        await _peerChar!.setNotifyValue(true);
        _peerNotifySub = _peerChar!.onValueReceived.listen((bytes) {
          if (bytes.isNotEmpty) {
            _towerPeerCount = bytes[0];
            _log('Tower peer count: $_towerPeerCount');
            notifyListeners();
          }
        });

        // Read initial peer count
        try {
          final val = await _peerChar!.read();
          if (val.isNotEmpty) _towerPeerCount = val[0];
        } catch (_) {}
      }

      _state = TowerState.connected;
      _log('Connected to tower! Peers on tower: $_towerPeerCount');
      notifyListeners();

      // Send PING to verify connection
      await sendCommand('PING');
    } catch (e) {
      _log('Connection failed: $e');
      await _disconnect();
      _scheduleReconnect();
    }
  }

  // ── Public API ───────────────────────────────────────

  /// Send a chat message JSON string through the tower for relay
  Future<bool> sendMessage(String jsonString) async {
    if (_state != TowerState.connected || _msgChar == null) return false;

    try {
      final bytes = utf8.encode(jsonString);
      if (bytes.length > 512) {
        _log('Message too large for BLE (${bytes.length} bytes), skipping tower relay');
        return false;
      }
      await _msgChar!.write(bytes, withoutResponse: false);
      _log('Sent to tower: ${jsonString.length > 60 ? '${jsonString.substring(0, 60)}...' : jsonString}');
      return true;
    } catch (e) {
      _log('Send failed: $e');
      return false;
    }
  }

  /// Send a command to the tower (STATUS, PING, RESET)
  Future<void> sendCommand(String cmd) async {
    if (_state != TowerState.connected || _cmdChar == null) return;
    try {
      await _cmdChar!.write(utf8.encode(cmd), withoutResponse: false);
      _log('Sent command: $cmd');
    } catch (e) {
      _log('Command failed: $e');
    }
  }

  // ── Disconnect / Reconnect ───────────────────────────

  Future<void> _disconnect() async {
    _msgNotifySub?.cancel();
    _msgNotifySub = null;
    _peerNotifySub?.cancel();
    _peerNotifySub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _msgChar = null;
    _peerChar = null;
    _cmdChar = null;
    _towerPeerCount = 0;

    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
  }

  void _onDisconnected() {
    _state = TowerState.disconnected;
    _msgChar = null;
    _peerChar = null;
    _cmdChar = null;
    _towerPeerCount = 0;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_autoReconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (_state == TowerState.disconnected) {
        _log('Auto-reconnect: scanning for tower...');
        startScan();
      }
    });
  }

  // ── Logging ──────────────────────────────────────────

  void _log(String msg) {
    debugPrint('[TOWER] $msg');
  }
}
