import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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

  // State
  CallState _state = CallState.idle;
  bool _isVideoCall = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeaker = true;
  String _remotePeer = '';
  DateTime? _callStartTime;
  bool _weAreGroupOwner = false;

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
  };

  // ── Wait for Wi-Fi Direct ──────────────────────────────

  /// Poll getConnectionInfo until groupFormed=true, or timeout
  Future<bool> _waitForWifiDirect({int maxWaitSeconds = 30}) async {
    debugPrint('[CALL] Waiting for Wi-Fi Direct connection...');
    for (int i = 0; i < maxWaitSeconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final info = await WifiDirectService.getConnectionInfo();
      final formed = info['groupFormed'] as bool? ?? false;
      if (formed) {
        debugPrint('[CALL] ✅ Wi-Fi Direct connected after ${i + 1}s');
        return true;
      }
      if (i % 5 == 4) {
        debugPrint('[CALL] Still waiting... (${i + 1}s)');
      }
    }
    debugPrint('[CALL] ❌ Wi-Fi Direct timeout after ${maxWaitSeconds}s');
    return false;
  }

  /// Get all local IPv4 addresses
  static Future<List<String>> _getLocalIPs() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: true,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            debugPrint('[CALL] Found IP: ${addr.address} (${iface.name})');
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      debugPrint('[CALL] Failed to get local IPs: $e');
    }
    return ips;
  }

  // ── Start a Call (Caller) ──────────────────────────────
  // 1. Create Wi-Fi Direct group (we become 192.168.49.1)
  // 2. Wait for group to form
  // 3. Send offer via mesh
  // 4. WebRTC set up happens AFTER Wi-Fi Direct is ready

  Future<void> startCall({required bool video}) async {
    if (_state != CallState.idle) return;
    _isVideoCall = video;
    _state = CallState.connecting;
    notifyListeners();

    try {
      // Step 1: Create Wi-Fi Direct group
      debugPrint('[CALL] Creating Wi-Fi Direct group...');
      await WifiDirectService.createGroup();
      _weAreGroupOwner = true;

      // Step 2: Wait for the group to fully form
      final connected = await _waitForWifiDirect(maxWaitSeconds: 10);
      debugPrint('[CALL] Group owner ready: $connected');

      // Step 3: Now set up WebRTC (after Wi-Fi Direct is ready)
      _state = CallState.offering;
      notifyListeners();

      await _createPeerConnection();
      await _getUserMedia(video);

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      final offer = await _pc!.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': video,
        },
      });
      await _pc!.setLocalDescription(offer);

      // Step 4: Send offer with our IPs
      final localIPs = await _getLocalIPs();

      await meshController.sendCallSignal(MeshPacketType.callOffer, {
        'sdp': offer.sdp,
        'type': offer.type,
        'video': video,
      });

      debugPrint('[CALL] Offer sent. My IPs: $localIPs');
    } catch (e) {
      debugPrint('[CALL] Failed to start call: $e');
      _state = CallState.idle;
      notifyListeners();
    }
  }

  // ── Answer a Call (Callee) ─────────────────────────────
  // 1. Trigger Wi-Fi Direct discover+connect (shows prompt)
  // 2. WAIT for the connection to actually establish
  // 3. THEN set up WebRTC (so ICE naturally finds 192.168.49.x)

  Future<void> answerCall() async {
    if (pendingOffer == null) return;
    _state = CallState.connecting;
    notifyListeners();

    try {
      final offerData = pendingOffer!;
      _isVideoCall = offerData['video'] as bool? ?? false;

      // Step 1: Start Wi-Fi Direct discovery + connection
      debugPrint('[CALL] Starting Wi-Fi Direct discover+connect...');
      await WifiDirectService.discoverAndConnect();

      // Step 2: WAIT for Wi-Fi Direct to actually connect
      // (This waits for the user to accept the prompt on their phone)
      final connected = await _waitForWifiDirect(maxWaitSeconds: 30);
      if (!connected) {
        debugPrint(
          '[CALL] Wi-Fi Direct failed — trying anyway with existing IPs',
        );
      }

      // Step 3: NOW set up WebRTC (Wi-Fi Direct IPs are available)
      _state = CallState.connected;
      notifyListeners();

      await _createPeerConnection();
      await _getUserMedia(_isVideoCall);

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          offerData['sdp'] as String?,
          offerData['type'] as String?,
        ),
      );

      final answer = await _pc!.createAnswer({
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': _isVideoCall,
        },
      });
      await _pc!.setLocalDescription(answer);

      final localIPs = await _getLocalIPs();

      await meshController.sendCallSignal(MeshPacketType.callAnswer, {
        'sdp': answer.sdp,
        'type': answer.type,
      });

      _callStartTime = DateTime.now();
      pendingOffer = null;
      debugPrint('[CALL] Answer sent. My IPs: $localIPs');
    } catch (e) {
      debugPrint('[CALL] Failed to answer call: $e');
      _state = CallState.idle;
      notifyListeners();
    }
  }

  // ── Reject / End ───────────────────────────────────────

  void rejectCall() {
    pendingOffer = null;
    meshController.sendCallSignal(MeshPacketType.callEnd, {});
    _state = CallState.idle;
    notifyListeners();
  }

  Future<void> endCall() async {
    if (_state == CallState.idle) return;
    debugPrint('[CALL] Ending call');
    await meshController.sendCallSignal(MeshPacketType.callEnd, {});
    await _cleanup();
  }

  // ── Controls ───────────────────────────────────────────

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

  // ── Signal Handler ─────────────────────────────────────

  void _onSignal(Map<String, dynamic> signal) async {
    final type = signal['signalType'] as String?;
    debugPrint('[CALL] Received signal: $type');

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
        if (_state != CallState.offering) return;
        try {
          await _pc!.setRemoteDescription(
            RTCSessionDescription(
              signal['sdp'] as String?,
              signal['type'] as String?,
            ),
          );
          _state = CallState.connected;
          _callStartTime = DateTime.now();
          notifyListeners();
          debugPrint('[CALL] ✅ Connected!');
        } catch (e) {
          debugPrint('[CALL] Failed to set remote desc: $e');
        }
        break;

      case 'iceCandidate':
        try {
          final candidate = RTCIceCandidate(
            signal['candidate'] as String?,
            signal['sdpMid'] as String?,
            signal['sdpMLineIndex'] as int?,
          );
          await _pc?.addCandidate(candidate);
        } catch (e) {
          debugPrint('[CALL] Failed to add ICE: $e');
        }
        break;

      case 'callEnd':
        await _cleanup();
        break;
    }
  }

  // ── Internal ───────────────────────────────────────────

  Future<void> _createPeerConnection() async {
    _pc = await createPeerConnection(_rtcConfig);

    _pc!.onIceCandidate = (candidate) {
      debugPrint('[CALL] ICE candidate: ${candidate.candidate}');
      meshController.sendCallSignal(MeshPacketType.iceCandidate, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onTrack = (event) {
      debugPrint('[CALL] onTrack: ${event.streams.length} streams');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        notifyListeners();
      }
    };

    // Legacy API — Android flutter_webrtc often fires this
    _pc!.onAddStream = (stream) {
      debugPrint('[CALL] onAddStream: ${stream.getTracks().length} tracks');
      _remoteStream = stream;
      notifyListeners();
    };

    _pc!.onIceConnectionState = (state) {
      debugPrint('[CALL] ICE: $state');
    };

    _pc!.onConnectionState = (state) {
      debugPrint('[CALL] Conn: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cleanup();
      }
    };
  }

  Future<void> _getUserMedia(bool video) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {
              'mandatory': {
                'minWidth': '480',
                'minHeight': '640',
                'minFrameRate': '15',
              },
              'facingMode': 'user',
            }
          : false,
    });
    Helper.setSpeakerphoneOn(true);
  }

  Future<void> _cleanup() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;

    // Clean up Wi-Fi Direct group
    if (_weAreGroupOwner) {
      await WifiDirectService.removeGroup();
      _weAreGroupOwner = false;
    }

    _state = CallState.idle;
    _isMuted = false;
    _isCameraOff = false;
    _callStartTime = null;
    pendingOffer = null;
    notifyListeners();
  }
}
