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

  // State
  CallState _state = CallState.idle;
  bool _isVideoCall = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeaker = true;
  bool _isCaller = false;
  String _remotePeer = '';
  DateTime? _callStartTime;

  // ICE candidate buffer
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;

  // ── Visible status log (shown on call screen) ──────────
  final List<String> statusLog = [];
  String? errorMessage;

  void _log(String msg) {
    debugPrint('[CALL] $msg');
    statusLog.add(msg);
    if (statusLog.length > 60) statusLog.removeAt(0);
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
  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
    'iceCandidatePoolSize': 2,
  };

  // ══════════════════════════════════════════════════════════
  //  TWO-PHASE OFFLINE CALL FLOW
  //
  //  Phase 1 (NC mesh / Bluetooth):
  //    Caller → invite → Callee accepts → Caller → "ready" signal
  //
  //  Phase 2 (Wi-Fi Direct + TCP):
  //    BOTH sides stop mesh (releases Wi-Fi Direct adapter!)
  //    Caller: creates WFD group → starts TCP server
  //    Callee: discovers WFD group → connects TCP
  //    WebRTC signaling over TCP, media over WFD p2p0 interface
  //
  //  Key insight: NC holds the Wi-Fi Direct adapter exclusively.
  //  We MUST stop mesh before manual Wi-Fi Direct will work.
  //  After call ends, mesh is restarted automatically.
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
    notifyListeners();

    // Pre-check: mesh peers
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
    notifyListeners();

    // Check permissions
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
    // Flow continues in _onSignal when 'iceCandidate' with ready:true arrives
  }

  // ── Phase 2: Wi-Fi Direct setup ───────────────────────

  /// Caller received acceptance → send ready signal → stop mesh → WFD group → TCP
  Future<void> _callerStartPhase2() async {
    _state = CallState.connecting;
    notifyListeners();

    try {
      // Send "ready" signal over mesh so callee knows to start
      _log('Sending ready signal over mesh...');
      await meshController.sendCallSignal(MeshPacketType.iceCandidate, {
        'ready': true,
      });

      // Wait for the signal to be delivered over BT (~1-2s)
      _log('Waiting for signal delivery...');
      await Future.delayed(const Duration(seconds: 2));

      // CRITICAL: Stop mesh to release the Wi-Fi Direct adapter
      _log('Stopping mesh (releasing Wi-Fi adapter)...');
      meshController.stopMesh();
      await Future.delayed(const Duration(seconds: 1));

      // Create Wi-Fi Direct group (become Group Owner)
      _log('Creating Wi-Fi Direct group...');
      final result = await WifiDirectService.createGroup();
      final groupFormed = result['groupFormed'] as bool? ?? false;
      final goAddr = result['groupOwnerAddress'] as String? ?? _groupOwnerIp;
      _log('WFD group: formed=$groupFormed addr=$goAddr');

      // Wait for p2p0 interface
      final gotIp = await _waitForP2pInterface();
      if (!gotIp) {
        _log('No p2p0 (using 192.168.49.1 anyway)');
      }

      // CRITICAL: Bind process to p2p0 network so WebRTC sees it
      _log('Binding process to p2p network...');
      final bound = await WifiDirectService.bindToP2pNetwork();
      _log('Process bound to p2p: $bound');

      // Start TCP signaling server
      _log('Starting TCP server on port $_signalingPort...');
      _tcpServer = await ServerSocket.bind(
        InternetAddress.anyIPv4, _signalingPort);
      _log('TCP server listening — waiting for callee...');

      // Wait for callee to connect (timeout 90s for slow discovery)
      final socket = await _tcpServer!.first.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException(
          'Callee never connected (90s timeout)'),
      );
      _tcpSocket = socket;
      _log('Callee connected via TCP!');

      _listenToTcpSocket(socket);
      await _startWebRtcAsCaller();
    } catch (e) {
      errorMessage = 'Call setup failed: $e';
      _log('ERROR: $e');
      await _cleanup();
    }
  }

  /// Callee received ready signal → stop mesh → discover WFD → TCP → wait for offer
  Future<void> _calleeStartPhase2() async {
    try {
      // Wait a moment for the caller to finish stopping mesh + creating group
      _log('Waiting for caller to set up group...');
      await Future.delayed(const Duration(seconds: 4));

      // CRITICAL: Stop mesh to release the Wi-Fi Direct adapter
      _log('Stopping mesh (releasing Wi-Fi adapter)...');
      meshController.stopMesh();
      await Future.delayed(const Duration(seconds: 1));

      // Try discovering and connecting to the caller's WFD group
      // Retry multiple times — discovery can be slow
      bool connected = false;
      for (int attempt = 1; attempt <= 3 && !connected; attempt++) {
        _log('Wi-Fi Direct discovery attempt $attempt/3...');
        final result = await WifiDirectService.discoverAndConnect();
        final groupFormed = result['groupFormed'] as bool? ?? false;
        _log('WFD: groupFormed=$groupFormed');
        if (groupFormed) {
          connected = true;
          break;
        }
        // Wait before retry
        if (attempt < 3) {
          _log('Retrying in 3s...');
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      // Even if discoverAndConnect said false, poll getConnectionInfo
      // (connection may form asynchronously)
      if (!connected) {
        _log('Discovery returned false — polling for connection...');
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

      // Wait for p2p0 interface
      final gotIp = await _waitForP2pInterface();
      if (!gotIp) {
        _log('WARNING: No p2p0 IP — trying TCP anyway...');
      }

      // CRITICAL: Bind process to p2p0 network so WebRTC sees it
      _log('Binding process to p2p network...');
      final bound = await WifiDirectService.bindToP2pNetwork();
      _log('Process bound to p2p: $bound');

      // Connect TCP to group owner
      _log('Connecting TCP to $_groupOwnerIp:$_signalingPort...');
      Socket? sock;
      for (int attempt = 1; attempt <= 8; attempt++) {
        try {
          sock = await Socket.connect(
            _groupOwnerIp, _signalingPort,
            timeout: const Duration(seconds: 8),
          );
          break;
        } catch (e) {
          _log('TCP attempt $attempt/8: $e');
          if (attempt < 8) {
            await Future.delayed(const Duration(seconds: 3));
          }
        }
      }
      if (sock == null) {
        throw Exception('Could not connect TCP to caller after 8 attempts');
      }
      _tcpSocket = sock;
      _log('TCP connected to caller!');

      _listenToTcpSocket(sock);
      _log('Waiting for WebRTC offer...');
    } catch (e) {
      errorMessage = 'Connect failed: $e';
      _log('ERROR: $e');
      await _cleanup();
    }
  }

  /// Wait up to 15s for a p2p0 / Wi-Fi Direct interface with an IP
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
              _log('Got IP: ${addr.address} (${iface.name})');
              return true;
            }
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // Dump all interfaces for debug
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

    _sendTcpSignal({
      'signalType': 'offer',
      'sdp': offer.sdp,
      'type': offer.type,
      'video': _isVideoCall,
    });
    _log('Offer sent via TCP!');
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

      _sendTcpSignal({
        'signalType': 'answer',
        'sdp': answer.sdp,
        'type': answer.type,
      });
      _log('Answer sent via TCP! ICE negotiating...');
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
    final candidate = RTCIceCandidate(
      signal['candidate'] as String?,
      signal['sdpMid'] as String?,
      signal['sdpMLineIndex'] as int?,
    );
    if (_remoteDescSet && _pc != null) {
      try {
        await _pc!.addCandidate(candidate);
        _log('ICE candidate added');
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
        // Caller sent an invite
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
        // Callee accepted
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
        // "ready" signal from caller OR a real ICE candidate
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
      final c = candidate.candidate ?? '';
      final short = c.length > 60 ? '${c.substring(0, 60)}...' : c;
      _log('ICE out: $short');
      _sendTcpSignal({
        'signalType': 'iceCandidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onIceGatheringState = (gatherState) {
      _log('ICE gathering: $gatherState');
    };

    _pc!.onTrack = (event) {
      _log('onTrack: ${event.track?.kind} streams=${event.streams.length}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _log('Remote stream (${_remoteStream!.getTracks().length} tracks)');
        notifyListeners();
      } else if (event.track != null) {
        _log('Orphan track — adding manually');
        _addOrphanTrack(event.track!);
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
        _log('ICE CONNECTED — media flowing!');
        notifyListeners();
      } else if (iceState ==
          RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _log('ICE FAILED — no media path');
        errorMessage = 'ICE failed — phones cannot reach each other';
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

    // Close WebRTC
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;
    _pendingCandidates.clear();
    _remoteDescSet = false;

    // Unbind from p2p network (restore default routing)
    try {
      await WifiDirectService.unbindNetwork();
      _log('Network unbound');
    } catch (_) {}

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
    notifyListeners();

    // Restart mesh (was stopped for Wi-Fi Direct)
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
