import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';

class CallScreen extends StatefulWidget {
  final CallService callService;

  const CallScreen({super.key, required this.callService});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  Timer? _durationTimer;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initRenderers();
    widget.callService.addListener(_onCallUpdate);
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _updateStreams();
  }

  void _onCallUpdate() {
    if (!mounted) return;
    _updateStreams();
    setState(() {});

    // Start duration timer when connected
    if (widget.callService.state == CallState.connected &&
        _durationTimer == null) {
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final start = widget.callService.callStartTime;
        if (start != null) {
          setState(() => _duration = DateTime.now().difference(start));
        }
      });
    }

    // End — pop back
    if (widget.callService.state == CallState.idle) {
      _durationTimer?.cancel();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  void _updateStreams() {
    final local = widget.callService.localStream;
    final remote = widget.callService.remoteStream;
    if (local != null) _localRenderer.srcObject = local;
    if (remote != null) _remoteRenderer.srcObject = remote;
  }

  @override
  void dispose() {
    widget.callService.removeListener(_onCallUpdate);
    _durationTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.callService;
    final isVideo = cs.isVideoCall;
    final isConnected = cs.state == CallState.connected;

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Stack(
        children: [
          // Background — remote video or dark gradient
          if (isVideo && cs.remoteStream != null)
            Positioned.fill(
              child: RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            )
          else
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0A1A2A), Color(0xFF0D0D0D)],
                  ),
                ),
              ),
            ),

          // Audio call center content
          if (!isVideo || cs.remoteStream == null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Peer avatar
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.cyan.withValues(alpha: 0.15),
                      border: Border.all(
                        color: AppTheme.cyan.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.person_outline_rounded,
                      color: AppTheme.cyan,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    isConnected ? 'Connected' : 'Calling...',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  if (isConnected) ...[
                    const SizedBox(height: 8),
                    Text(
                      _formatDuration(_duration),
                      style: GoogleFonts.firaCode(
                        color: AppTheme.cyan,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  if (!isConnected) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.cyan.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),

          // Duration overlay for video call
          if (isVideo && isConnected)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _formatDuration(_duration),
                    style: GoogleFonts.firaCode(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

          // Local video preview (corner)
          if (isVideo && cs.localStream != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              right: 16,
              child: GestureDetector(
                onTap: () => cs.switchCamera(),
                child: Container(
                  width: 100,
                  height: 140,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.cyan.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: RTCVideoView(
                      _localRenderer,
                      mirror: true,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),
            ),

          // Call type indicator
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isVideo
                        ? Icons.videocam_rounded
                        : Icons.phone_in_talk_rounded,
                    color: AppTheme.green,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isVideo ? 'Video Call' : 'Audio Call',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                24,
                20,
                24,
                MediaQuery.of(context).padding.bottom + 24,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Mute
                  _buildControlBtn(
                    icon: cs.isMuted
                        ? Icons.mic_off_rounded
                        : Icons.mic_none_rounded,
                    label: cs.isMuted ? 'Unmute' : 'Mute',
                    isActive: cs.isMuted,
                    onTap: cs.toggleMute,
                  ),

                  // Speaker
                  _buildControlBtn(
                    icon: cs.isSpeaker
                        ? Icons.volume_up_rounded
                        : Icons.hearing_rounded,
                    label: cs.isSpeaker ? 'Speaker' : 'Earpiece',
                    isActive: cs.isSpeaker,
                    onTap: cs.toggleSpeaker,
                  ),

                  // Video toggle (only in video call)
                  if (isVideo)
                    _buildControlBtn(
                      icon: cs.isCameraOff
                          ? Icons.videocam_off_rounded
                          : Icons.videocam_rounded,
                      label: cs.isCameraOff ? 'Cam On' : 'Cam Off',
                      isActive: !cs.isCameraOff,
                      onTap: cs.toggleCamera,
                    ),

                  // Switch Camera (only in video call)
                  if (isVideo)
                    _buildControlBtn(
                      icon: Icons.cameraswitch_rounded,
                      label: 'Flip',
                      onTap: cs.switchCamera,
                    ),

                  // End Call
                  _buildEndCallBtn(onTap: () => cs.endCall()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required String label,
    bool isActive = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? AppTheme.cyan.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.1),
              border: Border.all(
                color: isActive
                    ? AppTheme.cyan.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.firaCode(
              color: AppTheme.textSecondary,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEndCallBtn({required VoidCallback onTap}) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.heavyImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.red,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.red.withValues(alpha: 0.4),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'End',
            style: GoogleFonts.firaCode(color: AppTheme.red, fontSize: 9),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }
}
