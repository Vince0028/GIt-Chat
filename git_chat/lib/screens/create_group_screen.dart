import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/group.dart';
import '../services/storage_service.dart';
import '../services/mesh_controller.dart';

class CreateGroupScreen extends StatefulWidget {
  final MeshController meshController;

  const CreateGroupScreen({super.key, required this.meshController});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  bool _isCreating = false;
  bool _broadcastInvite = true;

  void _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _isCreating = true);
    HapticFeedback.mediumImpact();

    final username = StorageService.getUsername() ?? 'anon';
    final groupId = MeshController.generateGroupId();
    final key = MeshController.generateSymmetricKey();

    final group = MeshGroup(
      id: groupId,
      name: name,
      createdBy: username,
      createdAt: DateTime.now(),
      members: [username],
      symmetricKey: key,
    );

    // Save locally
    await StorageService.saveGroup(group);

    // Broadcast invite to all connected peers
    if (_broadcastInvite) {
      await widget.meshController.sendGroupInvite(group);
    }

    if (mounted) {
      Navigator.of(context).pop(group);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerCount = widget.meshController.connectedPeers.length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '> new group',
          style: GoogleFonts.firaCode(
            color: AppTheme.green,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.purple.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.group_add,
                          color: AppTheme.purple,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Create Mesh Group',
                              style: GoogleFonts.firaCode(
                                color: AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Encrypted. Decentralized. Yours.',
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
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Group name input
            Text(
              '> group name:',
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '\$ ',
                  style: GoogleFonts.firaCode(
                    color: AppTheme.green,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    autofocus: true,
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      hintText: 'APC_HACKERS',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintStyle: GoogleFonts.firaCode(
                        color: AppTheme.textMuted,
                        fontSize: 16,
                      ),
                    ),
                    onSubmitted: (_) => _createGroup(),
                    textInputAction: TextInputAction.done,
                  ),
                ),
              ],
            ),
            const Divider(color: AppTheme.border, height: 1),
            const SizedBox(height: 20),

            // Broadcast toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi_tethering, color: AppTheme.cyan, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Auto-invite nearby peers',
                          style: GoogleFonts.firaCode(
                            color: AppTheme.textPrimary,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          '$peerCount peers in range',
                          style: GoogleFonts.firaCode(
                            color: AppTheme.textMuted,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _broadcastInvite,
                    onChanged: (v) => setState(() => _broadcastInvite = v),
                    activeThumbColor: AppTheme.green,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Info
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '// how it works',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _infoLine('A unique GroupID + Key is generated'),
                  _infoLine('Members get the key via BLE handshake'),
                  _infoLine('Messages tagged with GroupID hop via mesh'),
                  _infoLine('Non-members relay but can\'t read'),
                ],
              ),
            ),

            const Spacer(),

            // Create button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCreating ? null : _createGroup,
                icon: _isCreating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.bgDark,
                        ),
                      )
                    : const Icon(Icons.add_circle_outline, size: 18),
                label: Text(_isCreating ? 'CREATING...' : 'CREATE GROUP'),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _infoLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: GoogleFonts.firaCode(
              color: AppTheme.green,
              fontSize: 10,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 10,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
