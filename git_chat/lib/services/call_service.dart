import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'mesh_controller.dart';
import 'wifi_direct_service.dart';

enum CallState { idle, offering, ringing, connecting, connected, ended }

class CallService extends ChangeNotifier {
  final MeshController meshController;
  StreamSubscription<Map<String, dynamic>>? _signalSub;

  // WebRTC
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // TCP signaling over Wi-Fi Direct
  ServerSocket? _tcpServer;
  Socket? _tcpSocket;
  final StringBuffer _tcpBuffer = StringBuffer();
  static const int _signalingPort = 29876;
  static const String _groupOwnerIp = '192.168.49.1';

  // ── UDP Relay ──────────────────────────────────────────
  // WebRTC only sees 127.0.0.1 because p2p0 isn't in Android's
  // ConnectivityManager. We run a UDP relay on 0.0.0.0:_relayPort
  // that bridges loopback ↔ p2p0 transparently.
  //
  // WebRTC thinks remote is at 127.0.0.1:_relayPort (loopback).
  // Relay forwards those packets to the real remote p2p0 IP.
  // Incoming packets from p2p0 are forwarded to WebRTC on loopback.
  static const int _relayPort = 59876;
  RawDatagramSocket? _relaySocket;
  String? _remoteP2pIp;
  int? _webrtcLocalPort; // learned from first loopback packet
  final List<Datagram> _relayBuffer = [];
  bool _relaySentSyntheticCandidate = false;

  // State
  CallState _state = CallState.idle;
  bool _isVideoCall = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeaker = true;
  bool _isCaller = false;
  String _remotePeer = '';
  DateTime? _callStartTime;
  bool _phase2Started = false;  // Guard: prevent multiple Phase 2 invocations

  // ICE candidate buffer
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;

  // Local p2p0 IP (detected after Wi-Fi Direct forms)
  String? _localP2pIp;

  // ── Visible status log (shown on call screen) ──────────
  final List<String> statusLog = [];
  String? errorMessage;

  void _log(String msg) {
    debugPrint('[CALL] $msg');
    statusLog.add(msg);
    if (statusLog.length > 80) statusLog.removeAt(0);
    notifyListeners();
  }

  // Getters
  CallState get state => _state;
  bool get isVideoCall => _isVideoCall;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isSpeaker => _isSpeaker;
  String get remotePeer => _remotePeer;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  DateTime? get callStartTime => _callStartTime;
  int get connectedPeerCount => meshController.connectedPeers.length;

  Map<String, dynamic>? pendingOffer;

  CallService({required this.meshController}) {
    _signalSub = meshController.incomingCallSignals.listen(_onSignal);
  }

  @override
  void dispose() {
    _signalSub?.cancel();
    endCall();
    super.dispose();
  }

  // ── WebRTC Configuration ───────────────────────────────
  // No STUN — we're offline. UDP relay handles the bridging.
  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
    'iceCandidatePoolSize': 0,
  };

  // ══════════════════════════════════════════════════════════
  //  THREE-PHASE OFFLINE CALL FLOW
  //
  //  Phase 1 (NC mesh / Bluetooth):
  //    Call invite → accept → "ready" signal
  //
  //  Phase 2 (Wi-Fi Direct + TCP):
  //    Stop mesh → WFD group → TCP signaling → exchange p2p IPs
  //
  //  Phase 3 (UDP Relay + WebRTC):
  //    Start UDP relay (bridges loopback ↔ p2p0) → WebRTC with
  //    synthetic ICE candidates pointing to 127.0.0.1:relay.
  //    Relay transparently forwards packets to real p2p0 IPs.
  //
  //  Why relay? WebRTC's native lib only sees 127.0.0.1 because
  //  p2p0 isn't registered in Android's ConnectivityManager.
  //  The relay bridges between loopback (where WebRTC lives)
  //  and the p2p0 interface (where the remote actually is).
  // ══════════════════════════════════════════════════════════

  // ── Start a Call (Caller) ─────────────────────────────

  Future<void> startCall({required bool video}) async {
    if (_state != CallState.idle) return;

    statusLog.clear();
    errorMessage = null;
    _isVideoCall = video;
    _isCaller = true;
    _state = CallState.offering;
    _remoteDescSet = false;
    _pendingCandidates.clear();
    _relaySentSyntheticCandidate = false;
    _phase2Started = false;
    notifyListeners();
    final peerCount = meshController.connectedPeers.length;
    _log('Mesh peers: $peerCount');
    if (peerCount == 0) {
      errorMessage = 'No peers! Both phones need mesh active & nearby.';
      _log('ERROR: $errorMessage');
      _state = CallState.idle;
      notifyListeners();
      return;
    }

    // Pre-check: permissions
    final camOk = await Permission.camera.isGranted;
    final micOk = await Permission.microphone.isGranted;
    _log('Perms — cam:$camOk mic:$micOk');
    if (!micOk || (video && !camOk)) {
      _log('Requesting permissions...');
      if (video && !camOk) await Permission.camera.request();
      if (!micOk) await Permission.microphone.request();
      final camNow = await Permission.camera.isGranted;
      final micNow = await Permission.microphone.isGranted;
      if (!micNow || (video && !camNow)) {
        errorMessage = 'Camera/mic permission denied.';
        _log('ERROR: $errorMessage');
        _state = CallState.idle;
        notifyListeners();
        return;
      }
    }

    // Phase 1: Send call invite over NC mesh
    _log('Sending call invite over mesh...');
    try {
      await meshController.sendCallSignal(MeshPacketType.callOffer, {
        'video': video,
        'intent': true,
      });
      _log('Invite sent! Waiting for peer to accept...');
    } catch (e) {
      errorMessage = 'Failed to send invite: $e';
      _log('ERROR: $errorMessage');
      _state = CallState.idle;
      notifyListeners();
    }
  }

  // ── Answer a Call (Callee) ────────────────────────────

  Future<void> answerCall() async {
    if (pendingOffer == null) return;

    statusLog.clear();
    errorMessage = null;
    _isCaller = false;
    _isVideoCall = pendingOffer!['video'] as bool? ?? false;
    _state = CallState.connecting;
    _remoteDescSet = false;
    _pendingCandidates.clear();
    _relaySentSyntheticCandidate = false;
    _phase2Started = false;
    notifyListeners();
    final camOk = await Permission.camera.isGranted;
    final micOk = await Permission.microphone.isGranted;
    _log('Perms — cam:$camOk mic:$micOk');
    if (!micOk) await Permission.microphone.request();
    if (_isVideoCall && !camOk) await Permission.camera.request();

    // Phase 1: Send acceptance over mesh
    _log('Sending acceptance over mesh...');
    try {
      await meshController.sendCallSignal(MeshPacketType.callAnswer, {
        'accepted': true,
      });
      _log('Acceptance sent — waiting for ready signal...');
    } catch (e) {
      _log('Send accept warning: $e');
    }
    pendingOffer = null;
  }

  // ── Phase 2: Wi-Fi Direct + TCP setup ─────────────────

  /// Caller: send ready → stop mesh → WFD group → TCP → exchange IPs → relay → WebRTC
  Future<void> _callerStartPhase2() async {
    if (_phase2Started) {
      _log('Phase 2 already started (ignoring duplicate)');
      return;
    }
    _phase2Started = true;
    _state = CallState.connecting;
    notifyListeners();

    try {
      _log('Sending ready signal over mesh (3x for reliability)...');
      for (int i = 0; i < 3; i++) {
        await meshController.sendCallSignal(MeshPacketType.iceCandidate, {
          'ready': true,
        });
        if (i < 2) await Future.delayed(const Duration(milliseconds: 500));
      }

      _log('Waiting for signal delivery...');
      await Future.delayed(const Duration(seconds: 2));

      _log('Stopping mesh (releasing Wi-Fi adapter)...');
      meshController.stopMesh();
      await Future.delayed(const Duration(seconds: 1));

      // Remove any stale group from a previous call
      _log('Removing any stale Wi-Fi Direct group...');
      try { await WifiDirectService.removeGroup(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));

      _log('Creating Wi-Fi Direct group...');
      final result = await WifiDirectService.createGroup();
      final groupFormed = result['groupFormed'] as bool? ?? false;
      _log('WFD group: formed=$groupFormed');

      final gotIp = await _waitForP2pInterface();
      if (!gotIp) {
        _localP2pIp = _groupOwnerIp;
        _log('No p2p0 detected, using $_groupOwnerIp');
      }

      // Bind TCP to the p2p0 IP so it's reachable on that interface
      final bindAddr = _localP2pIp ?? _groupOwnerIp;
      _log('Starting TCP server on $bindAddr:$_signalingPort...');
      // Close any lingering server from a previous call
      try { _tcpServer?.close(); } catch (_) {}
      _tcpServer = null;
      try {
        _tcpServer = await ServerSocket.bind(
          InternetAddress(bindAddr), _signalingPort, shared: true);
      } catch (e) {
        _log('Bind to $bindAddr failed ($e), falling back to 0.0.0.0');
        _tcpServer = await ServerSocket.bind(
          InternetAddress.anyIPv4, _signalingPort, shared: true);
      }
      _log('TCP server listening — waiting for callee...');

      final socket = await _tcpServer!.first.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('Callee never connected to TCP'),
      );
      _tcpSocket = socket;
      _log('Callee connected via TCP!');
      _listenToTcpSocket(socket);

      // Exchange p2p IPs — send ours, wait for callee's
      _log('Sending p2p IP to callee...');
      _sendTcpSignal({
        'signalType': 'p2pInfo',
        'ip': _localP2pIp ?? _groupOwnerIp,
      });
      // WebRTC starts when we receive 'p2pInfo' from callee (in _handleTcpSignal)
    } catch (e) {
      errorMessage = 'Call setup failed: $e';
      _log('ERROR: $e');
      await _cleanup();
    }
  }

  /// Callee: stop mesh → discover WFD → TCP → exchange IPs → relay → wait for offer
  Future<void> _calleeStartPhase2() async {
    if (_phase2Started) {
      _log('Phase 2 already started (ignoring duplicate)');
      return;
    }
    _phase2Started = true;
    try {
      _log('Waiting for caller to set up group...');
      await Future.delayed(const Duration(seconds: 4));

      _log('Stopping mesh (releasing Wi-Fi adapter)...');
      meshController.stopMesh();
      await Future.delayed(const Duration(seconds: 1));

      // Remove any stale group from a previous call
      _log('Removing any stale Wi-Fi Direct group...');
      try { await WifiDirectService.removeGroup(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));

      bool connected = false;
      for (int attempt = 1; attempt <= 5 && !connected; attempt++) {
        _log('Wi-Fi Direct discovery attempt $attempt/5...');
        final result = await WifiDirectService.discoverAndConnect();
        final groupFormed = result['groupFormed'] as bool? ?? false;
        _log('WFD: groupFormed=$groupFormed');
        if (groupFormed) {
          connected = true;
          break;
        }
        if (attempt < 5) {
          _log('Retrying in 3s...');
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      if (!connected) {
        _log('Discovery returned false — polling connection info...');
        for (int i = 0; i < 20; i++) {
          final info = await WifiDirectService.getConnectionInfo();
          if (info['groupFormed'] == true) {
            _log('Group formed (async)!');
            connected = true;
            break;
          }
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      final gotIp = await _waitForP2pInterface();
      if (!gotIp) {
        _log('WARNING: No p2p0 IP — trying TCP anyway...');
      }

      // Verify we can actually reach the group owner
      final verifyInfo = await WifiDirectService.getConnectionInfo();
      _log('Pre-TCP verify: groupFormed=${verifyInfo['groupFormed']} '
           'owner=${verifyInfo['isGroupOwner']} '
           'addr=${verifyInfo['groupOwnerAddress']}');

      // Source-bind TCP to our p2p0 IP — forces traffic through the correct interface
      _log('Connecting TCP: ${_localP2pIp ?? "auto"} → $_groupOwnerIp:$_signalingPort');
      Socket? sock;
      for (int attempt = 1; attempt <= 10; attempt++) {
        try {
          if (_localP2pIp != null) {
            // Bind to our p2p0 IP so the OS routes through the right interface
            sock = await Socket.connect(
              _groupOwnerIp, _signalingPort,
              sourceAddress: InternetAddress(_localP2pIp!),
              timeout: const Duration(seconds: 8),
            );
          } else {
            sock = await Socket.connect(
              _groupOwnerIp, _signalingPort,
              timeout: const Duration(seconds: 8),
            );
          }
          break;
        } catch (e) {
          _log('TCP attempt $attempt/10: $e');
          // On attempt 5, re-check p2p IP (might have appeared late)
          if (attempt == 5 && _localP2pIp == null) {
            _log('Re-checking for p2p0 interface...');
            await _waitForP2pInterface();
            if (_localP2pIp != null) _log('Got late p2p IP: $_localP2pIp');
          }
          if (attempt < 10) await Future.delayed(const Duration(seconds: 3));
        }
      }
      if (sock == null) {
        throw Exception('TCP connect failed after 10 attempts');
      }
      _tcpSocket = sock;
      _log('TCP connected to caller!');
      _listenToTcpSocket(sock);

      // Callee knows caller is always 192.168.49.1
      // Start relay immediately + send our IP
      _remoteP2pIp = _groupOwnerIp;
      await _startRelay();
      _log('Relay started (remote=$_remoteP2pIp)');

      _sendTcpSignal({
        'signalType': 'p2pInfo',
        'ip': _localP2pIp ?? 'unknown',
      });
      _log('Sent p2p IP to caller. Waiting for offer...');
    } catch (e) {
      errorMessage = 'Connect failed: $e';
      _log('ERROR: $e');
      await _cleanup();
    }
  }

  // ── Phase 3: UDP Relay ────────────────────────────────

  /// Start the UDP relay that bridges loopback ↔ p2p0
  Future<void> _startRelay() async {
    _webrtcLocalPort = null;
    _relayBuffer.clear();

    _relaySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, _relayPort);
    _log('UDP relay on 0.0.0.0:$_relayPort');

    _relaySocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _relaySocket?.receive();
      if (dg == null) return;

      if (dg.address.isLoopback) {
        // From local WebRTC → forward to remote via p2p0
        _webrtcLocalPort = dg.port;
        if (_remoteP2pIp != null) {
          _relaySocket?.send(
            dg.data,
            InternetAddress(_remoteP2pIp!),
            _relayPort,
          );
        }
        // Drain any buffered packets from remote
        if (_relayBuffer.isNotEmpty) {
          for (final b in _relayBuffer) {
            _relaySocket?.send(
              b.data,
              InternetAddress.loopbackIPv4,
              _webrtcLocalPort!,
            );
          }
          _relayBuffer.clear();
        }
      } else {
        // From remote via p2p0 → forward to local WebRTC on loopback
        if (_webrtcLocalPort != null) {
          _relaySocket?.send(
            dg.data,
            InternetAddress.loopbackIPv4,
            _webrtcLocalPort!,
          );
        } else {
          // Buffer until we learn WebRTC's port
          if (_relayBuffer.length < 100) {
            _relayBuffer.add(dg);
          }
        }
      }
    });
  }

  void _stopRelay() {
    _relaySocket?.close();
    _relaySocket = null;
    _relayBuffer.clear();
    _webrtcLocalPort = null;
    _remoteP2pIp = null;
  }

  /// Send a synthetic ICE candidate pointing to our relay (127.0.0.1:_relayPort)
  void _sendSyntheticCandidate() {
    if (_relaySentSyntheticCandidate) return;
    _relaySentSyntheticCandidate = true;

    // High-priority host UDP candidate pointing to our local relay
    const synth =
        'candidate:relay 1 udp 2130706431 127.0.0.1 $_relayPort typ host generation 0';
    _log('Sending synthetic relay candidate');
    _sendTcpSignal({
      'signalType': 'iceCandidate',
      'candidate': synth,
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
  }

  /// Strip all a=candidate lines from SDP (we use synthetic trickle candidates only)
  String _stripCandidatesFromSdp(String sdp) {
    final lines = sdp.split('\n');
    final filtered =
        lines.where((l) => !l.trimLeft().startsWith('a=candidate:')).toList();
    return filtered.join('\n');
  }

  // ── p2p0 interface detection ──────────────────────────

  Future<bool> _waitForP2pInterface() async {
    _log('Waiting for p2p0 interface...');
    for (int i = 0; i < 30; i++) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: true,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback &&
                (iface.name.contains('p2p') ||
                    addr.address.startsWith('192.168.49'))) {
              _localP2pIp = addr.address;
              _log('Got IP: $_localP2pIp (${iface.name})');
              return true;
            }
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    try {
      final all = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: true);
      for (final iface in all) {
        for (final addr in iface.addresses) {
          _log('IF: ${addr.address} (${iface.name})');
        }
      }
    } catch (_) {}
    return false;
  }

  // ── TCP signaling channel ─────────────────────────────

  void _listenToTcpSocket(Socket socket) {
    socket.listen(
      (data) {
        _tcpBuffer.write(utf8.decode(data));
        while (_tcpBuffer.toString().contains('\n')) {
          final str = _tcpBuffer.toString();
          final idx = str.indexOf('\n');
          final line = str.substring(0, idx);
          _tcpBuffer.clear();
          _tcpBuffer.write(str.substring(idx + 1));
          if (line.trim().isNotEmpty) {
            try {
              _handleTcpSignal(jsonDecode(line) as Map<String, dynamic>);
            } catch (e) {
              _log('TCP parse error: $e');
            }
          }
        }
      },
      onError: (e) => _log('TCP error: $e'),
      onDone: () {
        _log('TCP connection closed');
        if (_state != CallState.idle && _state != CallState.connected) {
          _cleanup();
        }
      },
    );
  }

  void _sendTcpSignal(Map<String, dynamic> signal) {
    if (_tcpSocket == null) {
      _log('WARNING: TCP socket null');
      return;
    }
    try {
      _tcpSocket!.write('${jsonEncode(signal)}\n');
    } catch (e) {
      _log('TCP send error: $e');
    }
  }

  void _handleTcpSignal(Map<String, dynamic> signal) async {
    final type = signal['signalType'] as String?;
    _log('TCP: $type');
    switch (type) {
      case 'p2pInfo':
        // Remote sent their p2p0 IP
        final remoteIp = signal['ip'] as String?;
        _log('Remote p2p IP: $remoteIp');
        if (_isCaller && remoteIp != null && remoteIp != 'unknown') {
          // Caller now knows callee's IP → start relay → start WebRTC
          _remoteP2pIp = remoteIp;
          await _startRelay();
          _log('Relay started (remote=$_remoteP2pIp)');
          await _startWebRtcAsCaller();
        }
        // Callee: already started relay in _calleeStartPhase2
        break;
      case 'offer':
        await _handleRemoteOffer(signal);
        break;
      case 'answer':
        await _handleRemoteAnswer(signal);
        break;
      case 'iceCandidate':
        await _handleRemoteIce(signal);
        break;
      case 'callEnd':
        _log('Remote ended call');
        await _cleanup();
        break;
    }
  }

  // ── WebRTC as Caller ──────────────────────────────────

  Future<void> _startWebRtcAsCaller() async {
    _log('Getting ${_isVideoCall ? "camera + mic" : "mic"}...');
    await _getUserMedia(_isVideoCall);
    _log('Got local media OK');

    _log('Creating WebRTC peer connection...');
    await _createPeerConnection();
    _log('Peer connection created');

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    _log('Added ${_localStream!.getTracks().length} tracks');

    _log('Creating SDP offer...');
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _isVideoCall,
    });
    await _pc!.setLocalDescription(offer);

    // Strip real candidate lines — we use synthetic relay candidates
    final cleanSdp = _stripCandidatesFromSdp(offer.sdp ?? '');
    _sendTcpSignal({
      'signalType': 'offer',
      'sdp': cleanSdp,
      'type': offer.type,
      'video': _isVideoCall,
    });
    _log('Offer sent via TCP!');

    // Send synthetic candidate pointing to our relay
    _sendSyntheticCandidate();
  }

  Future<void> _handleRemoteOffer(Map<String, dynamic> signal) async {
    try {
      _log('Getting ${_isVideoCall ? "camera + mic" : "mic"}...');
      await _getUserMedia(_isVideoCall);
      _log('Got local media OK');

      _log('Creating WebRTC peer connection...');
      await _createPeerConnection();
      _log('Peer connection created');

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
      _log('Added ${_localStream!.getTracks().length} tracks');

      _log('Setting remote offer...');
      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          signal['sdp'] as String?,
          signal['type'] as String?,
        ),
      );
      _remoteDescSet = true;
      _log('Remote description set');
      await _drainPendingCandidates();

      _log('Creating SDP answer...');
      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _isVideoCall,
      });
      await _pc!.setLocalDescription(answer);

      final cleanSdp = _stripCandidatesFromSdp(answer.sdp ?? '');
      _sendTcpSignal({
        'signalType': 'answer',
        'sdp': cleanSdp,
        'type': answer.type,
      });
      _log('Answer sent via TCP! ICE negotiating...');

      // Send synthetic candidate pointing to our relay
      _sendSyntheticCandidate();
    } catch (e) {
      _log('Handle offer error: $e');
      errorMessage = 'WebRTC setup failed: $e';
      await _cleanup();
    }
  }

  Future<void> _handleRemoteAnswer(Map<String, dynamic> signal) async {
    try {
      _log('Setting remote answer...');
      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          signal['sdp'] as String?,
          signal['type'] as String?,
        ),
      );
      _remoteDescSet = true;
      _log('Remote answer set');
      if (_pendingCandidates.isNotEmpty) {
        _log('Draining ${_pendingCandidates.length} buffered ICE');
      }
      await _drainPendingCandidates();
      _log('ICE negotiating...');
    } catch (e) {
      _log('Handle answer error: $e');
    }
  }

  Future<void> _handleRemoteIce(Map<String, dynamic> signal) async {
    final candidateStr = signal['candidate'] as String? ?? '';
    final short =
        candidateStr.length > 50 ? '${candidateStr.substring(0, 50)}...' : candidateStr;
    final candidate = RTCIceCandidate(
      signal['candidate'] as String?,
      signal['sdpMid'] as String?,
      signal['sdpMLineIndex'] as int?,
    );
    if (_remoteDescSet && _pc != null) {
      try {
        await _pc!.addCandidate(candidate);
        _log('Remote ICE added: $short');
      } catch (e) {
        _log('ICE add failed: $e');
      }
    } else {
      _pendingCandidates.add(candidate);
      _log('ICE buffered (${_pendingCandidates.length})');
    }
  }

  // ── Signal Handler (NC mesh — Phase 1 only) ───────────

  void _onSignal(Map<String, dynamic> signal) async {
    final type = signal['signalType'] as String?;
    _log('Mesh: $type');

    switch (type) {
      case 'callOffer':
        if (_state != CallState.idle) {
          meshController.sendCallSignal(MeshPacketType.callEnd, {});
          return;
        }
        _remotePeer = signal['sourceId'] as String? ?? '';
        pendingOffer = signal;
        _state = CallState.ringing;
        notifyListeners();
        break;

      case 'callAnswer':
        if (_state != CallState.offering) {
          _log('Got answer but state=$_state (ignoring)');
          return;
        }
        if (signal['accepted'] == true) {
          _log('Peer accepted!');
          await _callerStartPhase2();
        }
        break;

      case 'iceCandidate':
        if (signal['ready'] == true && _state == CallState.connecting) {
          _log('Ready signal received from caller!');
          await _calleeStartPhase2();
        } else {
          await _handleRemoteIce(signal);
        }
        break;

      case 'callEnd':
        _log('Remote ended call');
        await _cleanup();
        break;
    }
  }

  Future<void> _drainPendingCandidates() async {
    if (_pc == null || !_remoteDescSet || _pendingCandidates.isEmpty) return;
    for (final c in _pendingCandidates) {
      try {
        await _pc!.addCandidate(c);
      } catch (e) {
        _log('Buffered ICE apply failed: $e');
      }
    }
    _log('Applied ${_pendingCandidates.length} buffered ICE');
    _pendingCandidates.clear();
  }

  // ── Reject / End ──────────────────────────────────────

  void rejectCall() {
    pendingOffer = null;
    meshController.sendCallSignal(MeshPacketType.callEnd, {});
    _state = CallState.idle;
    notifyListeners();
  }

  Future<void> endCall() async {
    if (_state == CallState.idle) return;
    _log('Ending call');
    _sendTcpSignal({'signalType': 'callEnd'});
    try {
      await meshController.sendCallSignal(MeshPacketType.callEnd, {});
    } catch (_) {}
    await _cleanup();
  }

  // ── Controls ──────────────────────────────────────────

  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !_isCameraOff);
    notifyListeners();
  }

  void toggleSpeaker() {
    _isSpeaker = !_isSpeaker;
    Helper.setSpeakerphoneOn(_isSpeaker);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  // ── WebRTC Internals ──────────────────────────────────

  Future<void> _createPeerConnection() async {
    _pc = await createPeerConnection(_rtcConfig);

    _pc!.onIceCandidate = (candidate) {
      // SUPPRESS all real ICE candidates — we use synthetic relay candidates only
      final c = candidate.candidate ?? '';
      final short = c.length > 60 ? '${c.substring(0, 60)}...' : c;
      _log('ICE local (suppressed): $short');
    };

    _pc!.onIceGatheringState = (gatherState) {
      _log('ICE gathering: $gatherState');
    };

    _pc!.onTrack = (event) {
      _log('onTrack: ${event.track.kind} streams=${event.streams.length}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _log('Remote stream (${_remoteStream!.getTracks().length} tracks)');
        notifyListeners();
      } else {
        _log('Orphan track — adding manually');
        _addOrphanTrack(event.track);
      }
    };

    _pc!.onAddStream = (stream) {
      _log('onAddStream: ${stream.getTracks().length} tracks');
      _remoteStream = stream;
      notifyListeners();
    };

    _pc!.onIceConnectionState = (iceState) {
      _log('ICE: $iceState');
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _state = CallState.connected;
        _callStartTime ??= DateTime.now();
        _log('*** ICE CONNECTED — media flowing! ***');
        notifyListeners();
      } else if (iceState ==
          RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _log('ICE FAILED');
        errorMessage = 'ICE failed — phones cannot reach each other';
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (connState) {
      _log('Conn: $connState');
      if (connState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (_state != CallState.connected) {
          _state = CallState.connected;
          _callStartTime ??= DateTime.now();
          notifyListeners();
        }
      } else if (connState ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          connState ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _log('Connection lost/failed');
        _cleanup();
      }
    };
  }

  Future<void> _addOrphanTrack(MediaStreamTrack track) async {
    try {
      _remoteStream ??= await createLocalMediaStream('remoteStream');
      _remoteStream!.addTrack(track);
      _log('Remote: ${_remoteStream!.getTracks().length} tracks');
      notifyListeners();
    } catch (e) {
      _log('Orphan track add failed: $e');
    }
  }

  Future<void> _getUserMedia(bool video) async {
    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24, 'max': 30},
            }
          : false,
    };
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    _log('Media: ${_localStream!.getAudioTracks().length}a ${_localStream!.getVideoTracks().length}v');
    Helper.setSpeakerphoneOn(true);
  }

  // ── Cleanup ───────────────────────────────────────────

  Future<void> _cleanup() async {
    _log('Cleaning up...');

    // Close TCP
    try { _tcpSocket?.close(); } catch (_) {}
    _tcpSocket = null;
    try { _tcpServer?.close(); } catch (_) {}
    _tcpServer = null;
    _tcpBuffer.clear();

    // Stop UDP relay
    _stopRelay();

    // Close WebRTC
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;
    _pendingCandidates.clear();
    _remoteDescSet = false;
    _localP2pIp = null;

    // Remove Wi-Fi Direct group
    try {
      await WifiDirectService.removeGroup();
      _log('Wi-Fi Direct group removed');
    } catch (_) {}

    _state = CallState.idle;
    _isMuted = false;
    _isCameraOff = false;
    _isCaller = false;
    _callStartTime = null;
    pendingOffer = null;
    _relaySentSyntheticCandidate = false;
    _phase2Started = false;
    notifyListeners();

    // Restart mesh
    try {
      _log('Restarting mesh...');
      await Future.delayed(const Duration(seconds: 2));
      await meshController.startMesh();
      _log('Mesh restarted OK');
    } catch (e) {
      _log('Mesh restart: $e');
    }
  }
}
