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
  bool _permissionShown = false;

  @override
  void initState() {
    super.initState();
    _username = StorageService.getUsername() ?? 'anon';
    _loadGroups();

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

  void _showJoinGroupDialog() {
    final groupIdController = TextEditingController();
    final passwordController = TextEditingController();

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
            const Icon(Icons.login, color: AppTheme.cyan, size: 20),
            const SizedBox(width: 8),
            Text(
              'Join Group',
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the Group ID and password\nshared by the group creator.',
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: groupIdController,
              autofocus: true,
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'MESH_XXXXXX',
                prefixIcon: const Icon(
                  Icons.tag,
                  color: AppTheme.cyan,
                  size: 18,
                ),
                hintStyle: GoogleFonts.firaCode(
                  color: AppTheme.textMuted,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: 'password (if required)',
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
            onPressed: () async {
              final groupId = groupIdController.text.trim().toUpperCase();
              final password = passwordController.text.trim();

              if (groupId.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> enter a group ID',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.red.withValues(alpha: 0.8),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                return;
              }

              // Check if already a member
              if (StorageService.isGroupMember(groupId)) {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> already a member of this group',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.orange.withValues(alpha: 0.8),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                return;
              }

              final result = await widget.meshController.joinGroupWithCredentials(
                groupId,
                password,
              );

              if (result == 'success') {
                _loadGroups();
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> joined group successfully! syncing history...',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.bgCard,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (result == 'not_found') {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> group not found. ensure a peer with this group is nearby.',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.red.withValues(alpha: 0.8),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (result == 'wrong_password') {
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
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.cyan),
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

  void _showPeerDetailsModal() {
    final peers = widget.meshController.connectedPeers;
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
            Row(
              children: [
                const Icon(
                  Icons.wifi_tethering,
                  color: AppTheme.cyan,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Connected Peers',
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.cyan.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${peers.length} connected',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.cyan,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (peers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '> no peers connected',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else
              ...peers.map(
                (peer) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgDark,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: peer.isConnected
                              ? AppTheme.green
                              : AppTheme.red,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: peer.isConnected
                                  ? AppTheme.green
                                  : AppTheme.red,
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.endpointName,
                              style: GoogleFonts.firaCode(
                                color: AppTheme.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'ID: ${peer.endpointId}',
                              style: GoogleFonts.firaCode(
                                color: AppTheme.textMuted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            peer.isConnected ? 'ONLINE' : 'OFFLINE',
                            style: GoogleFonts.firaCode(
                              color: peer.isConnected
                                  ? AppTheme.green
                                  : AppTheme.red,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Last: ${_formatTime(peer.lastSeen)}',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textMuted,
                              fontSize: 8,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
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
          // Peer count badge (tappable for details)
          GestureDetector(
            onTap: _showPeerDetailsModal,
            child: Container(
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'join',
            onPressed: _showJoinGroupDialog,
            backgroundColor: AppTheme.cyan,
            icon: const Icon(Icons.login, color: AppTheme.bgDark, size: 18),
            label: Text(
              'JOIN',
              style: GoogleFonts.firaCode(
                color: AppTheme.bgDark,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: _createGroup,
            backgroundColor: AppTheme.green,
            icon: const Icon(Icons.group_add, color: AppTheme.bgDark, size: 18),
            label: Text(
              'CREATE',
              style: GoogleFonts.firaCode(
                color: AppTheme.bgDark,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
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
    String lastMsg = 'No messages yet';
    if (broadcastMsgs.isNotEmpty) {
      final lastVisible = broadcastMsgs.lastWhere(
        (m) => !m.isDeleted,
        orElse: () => broadcastMsgs.last,
      );
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
    String preview = 'No messages yet';
    if (allMsgs.isNotEmpty) {
      final lastMsg = allMsgs.lastWhere(
        (m) => !m.isDeleted,
        orElse: () => allMsgs.last,
      );
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
            'tap CREATE or JOIN to get started',
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
