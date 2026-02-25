import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';
import '../services/permission_service.dart';
import 'peer_chat_screen.dart';

class DiscoveryScreen extends StatefulWidget {
  final BLEService bleService;

  const DiscoveryScreen({super.key, required this.bleService});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    widget.bleService.addListener(_onBLEUpdate);
    _startScanning();
  }

  void _onBLEUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _startScanning() async {
    final ok = await PermissionService.checkAndRequestAll(context);
    if (ok) {
      widget.bleService.startScan();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    widget.bleService.removeListener(_onBLEUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.bleService.peers;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(
              Icons.bluetooth_searching,
              color: AppTheme.cyan,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Discover Peers',
              style: GoogleFonts.firaCode(
                color: AppTheme.cyan,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          if (widget.bleService.isScanning)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.cyan.withValues(alpha: 0.7),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, color: AppTheme.cyan),
              onPressed: _startScanning,
            ),
        ],
      ),
      body: Column(
        children: [
          // Scan status bar
          _buildScanStatus(),

          // Peer list
          Expanded(
            child: peers.isEmpty ? _buildEmptyState() : _buildPeerList(peers),
          ),
        ],
      ),
    );
  }

  Widget _buildScanStatus() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final opacity = widget.bleService.isScanning
                  ? 0.3 + (_pulseController.value * 0.7)
                  : 0.3;
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.bleService.isScanning
                      ? AppTheme.cyan.withValues(alpha: opacity)
                      : AppTheme.textMuted,
                  shape: BoxShape.circle,
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Text(
            widget.bleService.isScanning
                ? '> scanning for bitchat peers...'
                : '> scan complete',
            style: GoogleFonts.firaCode(
              color: widget.bleService.isScanning
                  ? AppTheme.cyan
                  : AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
          const Spacer(),
          Text(
            '${widget.bleService.peers.length} found',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Opacity(
                opacity: widget.bleService.isScanning
                    ? 0.3 + (_pulseController.value * 0.4)
                    : 0.3,
                child: const Icon(
                  Icons.bluetooth_searching,
                  size: 64,
                  color: AppTheme.cyan,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            widget.bleService.isScanning
                ? '> searching nearby...'
                : '> no peers found',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'make sure other phones have\nBitChat open with Bluetooth on',
            textAlign: TextAlign.center,
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted.withValues(alpha: 0.6),
              fontSize: 11,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          if (!widget.bleService.isScanning)
            ElevatedButton.icon(
              onPressed: _startScanning,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('SCAN AGAIN'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.cyan,
                foregroundColor: AppTheme.bgDark,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPeerList(List<BLEPeer> peers) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: peers.length,
      itemBuilder: (context, index) {
        final peer = peers[index];
        return _buildPeerCard(peer);
      },
    );
  }

  Widget _buildPeerCard(BLEPeer peer) {
    final signalStrength = _getSignalLabel(peer.rssi);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: peer.isConnected ? AppTheme.green : AppTheme.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _onPeerTap(peer),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // BLE icon with connection status
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: peer.isConnected
                        ? AppTheme.green.withValues(alpha: 0.15)
                        : AppTheme.cyan.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    peer.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                    color: peer.isConnected ? AppTheme.green : AppTheme.cyan,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),

                // Name and details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        peer.username != null
                            ? '@${peer.username}'
                            : peer.deviceName,
                        style: GoogleFonts.firaCode(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _buildSignalBars(peer.rssi),
                          const SizedBox(width: 6),
                          Text(
                            signalStrength,
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${peer.rssi} dBm',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Connect/chat button
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: peer.isConnected
                        ? AppTheme.green.withValues(alpha: 0.15)
                        : AppTheme.cyan.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    peer.isConnected ? 'CHAT' : 'CONNECT',
                    style: GoogleFonts.firaCode(
                      color: peer.isConnected ? AppTheme.green : AppTheme.cyan,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignalBars(int rssi) {
    final bars = rssi > -60
        ? 3
        : rssi > -80
        ? 2
        : 1;
    return Row(
      children: List.generate(3, (i) {
        return Container(
          width: 3,
          height: 6 + (i * 3).toDouble(),
          margin: const EdgeInsets.only(right: 1),
          decoration: BoxDecoration(
            color: i < bars ? AppTheme.green : AppTheme.textMuted,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  String _getSignalLabel(int rssi) {
    if (rssi > -60) return 'strong';
    if (rssi > -80) return 'medium';
    return 'weak';
  }

  Future<void> _onPeerTap(BLEPeer peer) async {
    if (peer.isConnected) {
      // Navigate to chat with this peer
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                PeerChatScreen(bleService: widget.bleService, peer: peer),
          ),
        );
      }
    } else {
      // Connect first
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '> connecting to ${peer.username ?? peer.deviceName}...',
            style: GoogleFonts.firaCode(fontSize: 12),
          ),
          backgroundColor: AppTheme.bgCard,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );

      final success = await widget.bleService.connectToPeer(peer.deviceId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '> connected! tap again to chat.'
                  : '> connection failed. try again.',
              style: GoogleFonts.firaCode(fontSize: 12),
            ),
            backgroundColor: success
                ? AppTheme.green.withValues(alpha: 0.2)
                : AppTheme.red.withValues(alpha: 0.2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
