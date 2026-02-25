import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/permission_service.dart';

/// A modal bottom sheet that tells users to turn on Bluetooth, Wi-Fi,
/// and grant permissions before the mesh can start.
class PermissionModal {
  static Future<bool> show(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _PermissionModalContent(),
    );
    return result ?? false;
  }
}

class _PermissionModalContent extends StatefulWidget {
  const _PermissionModalContent();

  @override
  State<_PermissionModalContent> createState() =>
      _PermissionModalContentState();
}

class _PermissionModalContentState extends State<_PermissionModalContent>
    with SingleTickerProviderStateMixin {
  bool _isRequesting = false;
  bool _permissionsGranted = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    setState(() => _isRequesting = true);
    final granted = await PermissionService.requestPermissions();
    if (!mounted) return;
    setState(() {
      _isRequesting = false;
      _permissionsGranted = granted;
    });
    if (granted) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.border, width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.textMuted,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Icon(
                    Icons.bluetooth,
                    color: Color.lerp(
                      AppTheme.cyan,
                      AppTheme.green,
                      _pulseController.value,
                    ),
                    size: 28,
                  );
                },
              ),
              const SizedBox(width: 12),
              Text(
                '> MESH SETUP',
                style: GoogleFonts.firaCode(
                  color: AppTheme.green,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'GitChat needs these to build the mesh network',
            style: GoogleFonts.firaCode(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Permission items
          _buildPermItem(
            Icons.bluetooth,
            'Bluetooth',
            'Discover & connect to nearby devices',
            AppTheme.cyan,
          ),
          const SizedBox(height: 12),
          _buildPermItem(
            Icons.location_on,
            'Location',
            'Required by Android for Bluetooth scanning',
            AppTheme.orange,
          ),
          const SizedBox(height: 12),
          _buildPermItem(
            Icons.wifi_tethering,
            'Nearby Devices',
            'Peer-to-peer connection (no internet needed)',
            AppTheme.purple,
          ),
          const SizedBox(height: 28),

          // Tip box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.bgDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppTheme.cyan, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Turn on Bluetooth to start. No internet or Wi-Fi needed — everything is offline.',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Action button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isRequesting ? null : _requestPermissions,
              icon: _isRequesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.bgDark,
                      ),
                    )
                  : _permissionsGranted
                      ? const Icon(Icons.check_circle, size: 18)
                      : const Icon(Icons.shield_outlined, size: 18),
              label: Text(
                _isRequesting
                    ? 'REQUESTING...'
                    : _permissionsGranted
                        ? 'ALL SET!'
                        : 'GRANT PERMISSIONS',
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Skip (for testing on desktop/emulator)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'skip (testing only)',
              style: GoogleFonts.firaCode(
                color: AppTheme.textMuted,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermItem(
    IconData icon,
    String title,
    String desc,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.bgDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
