import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'mesh_controller.dart';

enum CallState { idle, offering, ringing, connected, ended }

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

  // Incoming call data (for the UI to show incoming call dialog)
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
      // No STUN/TURN needed — devices are on the same local network via Nearby Connections
    ],
    'sdpSemantics': 'unified-plan',
  };

  // ── Start a Call (Caller) ──────────────────────────────

  Future<void> startCall({required bool video}) async {
    if (_state != CallState.idle) return;
    _isVideoCall = video;
    _state = CallState.offering;
    notifyListeners();

    try {
      await _createPeerConnection();
      await _getUserMedia(video);

      // Add local tracks to peer connection
      _localStream!.getTracks().forEach((track) {
        _pc!.addTrack(track, _localStream!);
      });

      // Create offer
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);

      // Send offer via mesh
      await meshController.sendCallSignal(MeshPacketType.callOffer, {
        'sdp': offer.sdp,
        'type': offer.type,
        'video': video,
        'from': meshController.connectedPeers.isNotEmpty ? 'caller' : 'unknown',
      });

      debugPrint('[CALL] Offer sent');
    } catch (e) {
      debugPrint('[CALL] Failed to start call: $e');
      _state = CallState.idle;
      notifyListeners();
    }
  }

  // ── Answer a Call (Callee) ─────────────────────────────

  Future<void> answerCall() async {
    if (pendingOffer == null) return;
    _state = CallState.connected;
    notifyListeners();

    try {
      final offerData = pendingOffer!;
      _isVideoCall = offerData['video'] as bool? ?? false;

      await _createPeerConnection();
      await _getUserMedia(_isVideoCall);

      _localStream!.getTracks().forEach((track) {
        _pc!.addTrack(track, _localStream!);
      });

      // Set remote description (the offer)
      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          offerData['sdp'] as String?,
          offerData['type'] as String?,
        ),
      );

      // Create answer
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      // Send answer via mesh
      await meshController.sendCallSignal(MeshPacketType.callAnswer, {
        'sdp': answer.sdp,
        'type': answer.type,
      });

      _callStartTime = DateTime.now();
      pendingOffer = null;
      debugPrint('[CALL] Answer sent, call connected');
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
    _localStream?.getAudioTracks().forEach((t) {
      // On mobile, this switches between earpiece and speaker
      Helper.setSpeakerphoneOn(_isSpeaker);
    });
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
          // Already in a call — reject
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
          debugPrint('[CALL] Connected!');
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
          debugPrint('[CALL] Failed to add ICE candidate: $e');
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

    // ICE candidates → send to remote peer via mesh
    _pc!.onIceCandidate = (candidate) {
      meshController.sendCallSignal(MeshPacketType.iceCandidate, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // Remote stream arrived
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        notifyListeners();
        debugPrint('[CALL] Remote stream received');
      }
    };

    _pc!.onConnectionState = (state) {
      debugPrint('[CALL] Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cleanup();
      }
    };
  }

  Future<void> _getUserMedia(bool video) async {
    final constraints = <String, dynamic>{
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
    };
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
  }

  Future<void> _cleanup() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;
    _state = CallState.idle;
    _isMuted = false;
    _isCameraOff = false;
    _callStartTime = null;
    pendingOffer = null;
    notifyListeners();
  }
}
