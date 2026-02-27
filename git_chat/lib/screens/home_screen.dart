import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/group.dart';
import '../services/storage_service.dart';
import '../services/mesh_controller.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'permission_modal.dart';

class HomeScreen extends StatefulWidget {
  final MeshController meshController;

  const HomeScreen({super.key, required this.meshController});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<MeshGroup> _groups = [];
  String _username = '';
  StreamSubscription<MeshGroup>? _inviteSub;
  StreamSubscription<MeshGroup>? _passwordInviteSub;
  bool _permissionShown = false;

  @override
  void initState() {
    super.initState();
    _username = StorageService.getUsername() ?? 'anon';
    _loadGroups();

    // Listen for group invites from the mesh
    _inviteSub = widget.meshController.incomingGroupInvites.listen((group) {
      _loadGroups();
      _showInviteSnackbar(group);
    });

    // Listen for password-protected group invites
    _passwordInviteSub = widget.meshController.passwordProtectedInvites.listen((
      group,
    ) {
      _showPasswordDialog(group);
    });

    widget.meshController.addListener(_onMeshUpdate);

    // Show permission modal after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_permissionShown) {
        _permissionShown = true;
        _showPermissionModal();
      }
    });
  }

  Future<void> _showPermissionModal() async {
    if (!mounted) return;
    await PermissionModal.show(context);
  }

  void _onMeshUpdate() {
    if (mounted) setState(() {});
  }

  void _loadGroups() {
    setState(() {
      _groups = StorageService.getGroups();
    });
  }

  void _showInviteSnackbar(MeshGroup group) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '> New mesh group joined: ${group.name}',
          style: GoogleFonts.firaCode(fontSize: 12),
        ),
        backgroundColor: AppTheme.bgCard,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'OPEN',
          textColor: AppTheme.green,
          onPressed: () => _openGroupChat(group),
        ),
      ),
    );
  }

  void _showPasswordDialog(MeshGroup group) {
    if (!mounted) return;
    final passwordController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: Row(
          children: [
            const Icon(Icons.lock_outline, color: AppTheme.orange, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Join "${group.name}"',
                style: GoogleFonts.firaCode(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This group is password-protected.\nEnter the password to join.',
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: 'password',
                prefixIcon: const Icon(
                  Icons.key,
                  color: AppTheme.orange,
                  size: 18,
                ),
                hintStyle: GoogleFonts.firaCode(
                  color: AppTheme.textMuted,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'CANCEL',
              style: GoogleFonts.firaCode(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final entered = passwordController.text.trim();
              if (entered == group.password) {
                // Password correct — save and join
                final username = StorageService.getUsername() ?? 'anon';
                if (!group.members.contains(username)) {
                  group.members.add(username);
                }
                StorageService.saveGroup(group);
                _loadGroups();
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> joined "${group.name}" successfully',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.bgCard,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else {
                // Wrong password
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> wrong password!',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.red.withValues(alpha: 0.8),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.orange),
            child: Text(
              'JOIN',
              style: GoogleFonts.firaCode(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openGroupChat(MeshGroup group) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              meshController: widget.meshController,
              groupId: group.id,
              groupName: group.name,
            ),
          ),
        )
        .then((_) => _loadGroups());
  }

  void _openBroadcastChat() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          meshController: widget.meshController,
          isGlobalChat: true,
        ),
      ),
    );
  }

  void _createGroup() async {
    final result = await Navigator.of(context).push<MeshGroup>(
      MaterialPageRoute(
        builder: (_) =>
            CreateGroupScreen(meshController: widget.meshController),
      ),
    );
    if (result != null) {
      _loadGroups();
    }
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: Row(
          children: [
            const Icon(Icons.hub_outlined, color: AppTheme.cyan, size: 20),
            const SizedBox(width: 8),
            Text(
              'How GitChat Works',
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoSection(
                '🔗 Technology',
                AppTheme.cyan,
                'Uses Google Nearby Connections API with P2P_CLUSTER strategy — a fully decentralised mesh where every device is equal (no server, no internet needed).',
              ),
              _infoSection(
                '📡 Radios Used',
                AppTheme.green,
                '• Bluetooth Low Energy (BLE)\n• Bluetooth Classic\n• Wi-Fi Direct (P2P)\n\nAll three are used simultaneously for fastest discovery.',
              ),
              _infoSection(
                '📏 Range',
                AppTheme.orange,
                '• Bluetooth: ~10–30 m\n• Wi-Fi Direct: ~30–100 m\n\nActual range depends on walls, interference, and device hardware.',
              ),
              _infoSection(
                '✉️ Message Limit',
                AppTheme.textPrimary,
                'Text messages: up to ~31 KB per message (mesh BYTES payload limit). Typical chat messages are well under 1 KB.',
              ),
              _infoSection(
                '🖼️ Image Limit',
                AppTheme.purple,
                'Images are compressed to 300×300 px at 35% quality before sending (~8–25 KB). They are NOT relayed (TTL=0) to avoid flooding the mesh.',
              ),
              _infoSection(
                '🔁 Relay / Mesh Hop',
                AppTheme.textSecondary,
                'Text messages have TTL=5, meaning they can hop through up to 5 intermediate devices to reach peers out of direct range — extending the effective mesh range.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'GOT IT',
              style: GoogleFonts.firaCode(
                color: AppTheme.cyan,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoSection(String title, Color color, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.firaCode(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: GoogleFonts.firaCode(
              color: AppTheme.textSecondary,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _inviteSub?.cancel();
    _passwordInviteSub?.cancel();
    widget.meshController.removeListener(_onMeshUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerCount = widget.meshController.connectedPeers.length;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.terminal, color: AppTheme.green, size: 20),
            const SizedBox(width: 8),
            Text(
              'GitChat',
              style: GoogleFonts.firaCode(
                color: AppTheme.green,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'MESH',
                style: GoogleFonts.firaCode(
                  color: AppTheme.green,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          // Peer count badge
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: peerCount > 0
                  ? AppTheme.cyan.withValues(alpha: 0.12)
                  : AppTheme.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: peerCount > 0 ? AppTheme.cyan : AppTheme.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.wifi_tethering,
                  size: 14,
                  color: peerCount > 0 ? AppTheme.cyan : AppTheme.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  '$peerCount',
                  style: GoogleFonts.firaCode(
                    color: peerCount > 0 ? AppTheme.cyan : AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // ? Info button
          IconButton(
            icon: const Icon(
              Icons.help_outline_rounded,
              size: 20,
              color: AppTheme.textMuted,
            ),
            tooltip: 'How it works',
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // User status bar
          _buildStatusBar(),

          // Content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Broadcast chat tile
                _buildGlobalChatTile(),
                const SizedBox(height: 20),

                // Groups section header
                Row(
                  children: [
                    Text(
                      '> MESH GROUPS',
                      style: GoogleFonts.firaCode(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_groups.length} groups',
                      style: GoogleFonts.firaCode(
                        color: AppTheme.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Group list
                if (_groups.isEmpty) _buildEmptyGroups(),
                ..._groups.map(
                  (g) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildGroupTile(g),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroup,
        backgroundColor: AppTheme.green,
        child: const Icon(Icons.group_add, color: AppTheme.bgDark),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.meshController.isMeshActive
                  ? AppTheme.green
                  : AppTheme.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.meshController.isMeshActive
                      ? AppTheme.green
                      : AppTheme.red,
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '@$_username',
            style: GoogleFonts.firaCode(
              color: AppTheme.green,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Text(
            widget.meshController.isMeshActive ? 'mesh active' : 'mesh offline',
            style: GoogleFonts.firaCode(
              color: widget.meshController.isMeshActive
                  ? AppTheme.green
                  : AppTheme.red,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalChatTile() {
    final broadcastMsgs = StorageService.getMessages();
    // Find the last non-deleted message for preview
    final lastVisible = broadcastMsgs.lastWhere(
      (m) => !m.isDeleted,
      orElse: () => broadcastMsgs.isNotEmpty
          ? broadcastMsgs.last
          : throw StateError('empty'),
    );
    final hasAny = broadcastMsgs.isNotEmpty;
    String lastMsg = 'No messages yet';
    if (hasAny) {
      if (lastVisible.isDeleted) {
        lastMsg = '🗑 Message deleted';
      } else if (lastVisible.messageType == 'image') {
        lastMsg = '📷 Image';
      } else if (lastVisible.messageType == 'link') {
        lastMsg = '🔗 ${lastVisible.body}';
      } else {
        lastMsg = lastVisible.body;
      }
    }
    final msgCount = broadcastMsgs.where((m) => !m.isDeleted).length;

    return GestureDetector(
      onTap: _openBroadcastChat,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.green.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.green.withValues(alpha: 0.05),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.public, color: AppTheme.green, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Global Chat',
                        style: GoogleFonts.firaCode(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'GLOBAL',
                          style: GoogleFonts.firaCode(
                            color: AppTheme.green,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lastMsg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (msgCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$msgCount',
                  style: GoogleFonts.firaCode(
                    color: AppTheme.green,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              color: AppTheme.textMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupTile(MeshGroup group) {
    final allMsgs = StorageService.getMessages(groupId: group.id);
    final lastMsg = allMsgs.lastWhere(
      (m) => !m.isDeleted,
      orElse: () => allMsgs.isNotEmpty ? allMsgs.last : throw StateError(''),
    );
    String preview = 'No messages yet';
    if (allMsgs.isNotEmpty) {
      if (lastMsg.isDeleted) {
        preview = '🗑 Message deleted';
      } else if (lastMsg.messageType == 'image') {
        preview = '📷 Image';
      } else if (lastMsg.messageType == 'link') {
        preview = '🔗 ${lastMsg.body}';
      } else {
        preview = lastMsg.body;
      }
    }

    return GestureDetector(
      onTap: () => _openGroupChat(group),
      onLongPress: () => _showGroupOptions(group),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.group, color: AppTheme.purple, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          group.name,
                          style: GoogleFonts.firaCode(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (group.password != null &&
                          group.password!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.lock,
                          color: AppTheme.orange,
                          size: 12,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${group.members.length} members',
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textMuted,
                    fontSize: 9,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  group.id.substring(0, 10),
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textMuted,
                    fontSize: 8,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              color: AppTheme.textMuted,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyGroups() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            Icons.group_outlined,
            size: 48,
            color: AppTheme.textMuted.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            '> no mesh groups yet',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'tap + to create one',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted.withValues(alpha: 0.6),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  void _showGroupOptions(MeshGroup group) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              group.name,
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'ID: ${group.id}',
              style: GoogleFonts.firaCode(
                color: AppTheme.textMuted,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.share, color: AppTheme.cyan),
              title: Text(
                'Share to nearby peers',
                style: GoogleFonts.firaCode(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                widget.meshController.sendGroupInvite(group);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> broadcasting group invite...',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.bgCard,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppTheme.orange),
              title: Text(
                'Members: ${group.members.join(", ")}',
                style: GoogleFonts.firaCode(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
              onTap: () => Navigator.pop(ctx),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.red),
              title: Text(
                'Leave group',
                style: GoogleFonts.firaCode(color: AppTheme.red, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                StorageService.deleteGroup(group.id);
                _loadGroups();
              },
            ),
          ],
        ),
      ),
    );
  }
}
