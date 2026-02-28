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
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        // Use a StatefulBuilder + Timer so the modal refreshes every 3s
        return StatefulBuilder(
          builder: (innerCtx, setModalState) {
            // Start a timer that refreshes the modal content
            Timer? refreshTimer;
            void startTimer() {
              refreshTimer?.cancel();
              refreshTimer = Timer.periodic(
                const Duration(seconds: 3),
                (_) {
                  if (innerCtx.mounted) {
                    setModalState(() {}); // trigger rebuild with latest data
                  } else {
                    refreshTimer?.cancel();
                  }
                },
              );
            }

            // Schedule timer on first build
            WidgetsBinding.instance.addPostFrameCallback((_) => startTimer());

            final peers = widget.meshController.connectedPeers;

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header ──
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
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.bgDark,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Row 1: Status dot + Name + Online badge ──
                            Row(
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
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    peer.endpointName,
                                    style: GoogleFonts.firaCode(
                                      color: AppTheme.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (peer.isConnected
                                            ? AppTheme.green
                                            : AppTheme.red)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    peer.isConnected ? 'ONLINE' : 'OFFLINE',
                                    style: GoogleFonts.firaCode(
                                      color: peer.isConnected
                                          ? AppTheme.green
                                          : AppTheme.red,
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // ── Row 2: Device model ──
                            _peerDetailRow(
                              Icons.phone_android,
                              'Device',
                              peer.deviceModel ?? 'detecting...',
                              AppTheme.purple,
                            ),
                            const SizedBox(height: 4),
                            // ── Row 3: Estimated distance ──
                            _peerDetailRow(
                              Icons.social_distance,
                              'Distance',
                              peer.estimatedDistance ?? 'measuring...',
                              AppTheme.orange,
                            ),
                            const SizedBox(height: 4),
                            // ── Row 4: RTT latency ──
                            _peerDetailRow(
                              Icons.speed,
                              'Latency',
                              peer.lastRttMs != null
                                  ? '${peer.lastRttMs}ms RTT'
                                  : 'measuring...',
                              AppTheme.cyan,
                            ),
                            const SizedBox(height: 4),
                            // ── Row 5: Endpoint ID + last seen ──
                            Row(
                              children: [
                                Icon(
                                  Icons.tag,
                                  color: AppTheme.textMuted,
                                  size: 12,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    peer.endpointId,
                                    style: GoogleFonts.firaCode(
                                      color: AppTheme.textMuted,
                                      fontSize: 8,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  _formatTime(peer.lastSeen),
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
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Helper: builds a single detail row for the peer card
  Widget _peerDetailRow(
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: GoogleFonts.firaCode(
            color: AppTheme.textMuted,
            fontSize: 10,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: GoogleFonts.firaCode(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
              _infoIconSection(
                Icons.hub_outlined,
                'Mesh Technology',
                AppTheme.cyan,
                'Uses Google Nearby Connections API with P2P_CLUSTER strategy — a fully decentralised mesh where every device is equal (no server, no internet needed).',
              ),
              _infoIconSection(
                Icons.cell_tower,
                'Radios Used',
                AppTheme.green,
                '• Bluetooth Low Energy (BLE)\n• Bluetooth Classic\n• Wi-Fi Direct (P2P)\n\nAll three are used simultaneously for fastest discovery and connection.',
              ),
              _infoIconSection(
                Icons.social_distance,
                'Range & Distance',
                AppTheme.orange,
                '• Bluetooth: ~10–30 m\n• Wi-Fi Direct: ~30–100 m\n\nActual range depends on walls, interference, and device hardware. Peer distance is estimated via RTT ping every 3 seconds.',
              ),
              _infoIconSection(
                Icons.lock_outline,
                'Private Groups',
                AppTheme.purple,
                'Groups are private by default. Share the Group ID + password with others so they can join. Only members can read messages.',
              ),
              _infoIconSection(
                Icons.sync,
                'Message Sync',
                AppTheme.cyan,
                'Late joiners automatically sync past messages from connected peers via gossip protocol. No server needed — history lives on the mesh.',
              ),
              _infoIconSection(
                Icons.videocam_outlined,
                'Video & Audio Calls',
                AppTheme.green,
                'Peer-to-peer calls use Wi-Fi Direct for signaling and WebRTC for media. Calls work without internet via a local UDP relay bridge.',
              ),
              _infoIconSection(
                Icons.phone_android,
                'Peer Info',
                AppTheme.purple,
                'Tap the peer count to see connected peers, their device model, estimated distance, and RTT latency — all updated live every 3 seconds.',
              ),
              _infoIconSection(
                Icons.chat_bubble_outline,
                'Message Limit',
                AppTheme.textPrimary,
                'Text: up to ~31 KB per message. Typical chat messages are well under 1 KB.',
              ),
              _infoIconSection(
                Icons.image_outlined,
                'Image Sharing',
                AppTheme.orange,
                'Images are compressed to 300×300 px at 35% quality (~8–25 KB). They are NOT relayed (TTL=0) to avoid flooding the mesh.',
              ),
              _infoIconSection(
                Icons.repeat,
                'Relay / Mesh Hop',
                AppTheme.textSecondary,
                'Text messages have TTL=5 — they can hop through up to 5 intermediate devices to reach peers out of direct range, extending the effective mesh.',
              ),
              _infoIconSection(
                Icons.admin_panel_settings_outlined,
                'Group Management',
                AppTheme.orange,
                'Group creators can rename the group, kick members, clear messages, or delete the group entirely via long-press on any group tile.',
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

  Widget _infoIconSection(
      IconData icon, String title, Color color, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.firaCode(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Text(
              body,
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 11,
                height: 1.5,
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
    final username = StorageService.getUsername() ?? 'anon';
    final isAdmin = group.createdBy == username;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (innerCtx, setModalState) {
          // Re-read group from storage to get latest member list
          final freshGroup = StorageService.getGroup(group.id) ?? group;

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.purple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.group,
                          color: AppTheme.purple, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            freshGroup.name,
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'ID: ${freshGroup.id}',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isAdmin)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'ADMIN',
                          style: GoogleFonts.firaCode(
                            color: AppTheme.orange,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: AppTheme.border, height: 1),
                const SizedBox(height: 12),

                // ── Share credentials ──
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      const Icon(Icons.copy_all, color: AppTheme.cyan, size: 20),
                  title: Text(
                    'Copy Group ID',
                    style: GoogleFonts.firaCode(
                        color: AppTheme.textPrimary, fontSize: 12),
                  ),
                  subtitle: Text(
                    freshGroup.id,
                    style: GoogleFonts.firaCode(
                        color: AppTheme.cyan, fontSize: 10),
                  ),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: freshGroup.id));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '> group ID copied to clipboard!',
                          style: GoogleFonts.firaCode(fontSize: 12),
                        ),
                        backgroundColor: AppTheme.bgCard,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),

                // ── Broadcast invite ──
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi_tethering,
                      color: AppTheme.green, size: 20),
                  title: Text(
                    'Broadcast Invite to Peers',
                    style: GoogleFonts.firaCode(
                        color: AppTheme.textPrimary, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.meshController.sendGroupInvite(freshGroup);
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

                const SizedBox(height: 8),
                const Divider(color: AppTheme.border, height: 1),
                const SizedBox(height: 8),

                // ── Members section ──
                Text(
                  'MEMBERS (${freshGroup.members.length})',
                  style: GoogleFonts.firaCode(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...freshGroup.members.map(
                  (member) => Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          member == freshGroup.createdBy
                              ? Icons.shield
                              : Icons.person,
                          color: member == freshGroup.createdBy
                              ? AppTheme.orange
                              : AppTheme.cyan,
                          size: 16,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            member,
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textPrimary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        if (member == freshGroup.createdBy)
                          Text(
                            'OWNER',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.orange,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (member == username && member != freshGroup.createdBy)
                          Text(
                            'YOU',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.cyan,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        // Kick button (admin only, can't kick yourself)
                        if (isAdmin &&
                            member != username &&
                            member != freshGroup.createdBy)
                          GestureDetector(
                            onTap: () async {
                              await StorageService.removeMemberFromGroup(
                                  freshGroup.id, member);
                              setModalState(() {});
                              _loadGroups();
                            },
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.person_remove,
                                  color: AppTheme.red, size: 16),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 8),
                const Divider(color: AppTheme.border, height: 1),
                const SizedBox(height: 8),

                // ── Admin actions ──
                if (isAdmin) ...[
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit,
                        color: AppTheme.purple, size: 20),
                    title: Text(
                      'Rename Group',
                      style: GoogleFonts.firaCode(
                          color: AppTheme.textPrimary, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showRenameGroupDialog(freshGroup);
                    },
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_sweep,
                        color: AppTheme.orange, size: 20),
                    title: Text(
                      'Clear All Messages',
                      style: GoogleFonts.firaCode(
                          color: AppTheme.orange, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _confirmClearMessages(freshGroup.id, freshGroup.name);
                    },
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_forever,
                        color: AppTheme.red, size: 20),
                    title: Text(
                      'Delete Group',
                      style: GoogleFonts.firaCode(
                          color: AppTheme.red, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _confirmDeleteGroup(freshGroup);
                    },
                  ),
                ] else ...[
                  // ── Non-admin: Leave group ──
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.logout,
                        color: AppTheme.red, size: 20),
                    title: Text(
                      'Leave Group',
                      style: GoogleFonts.firaCode(
                          color: AppTheme.red, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      StorageService.deleteGroup(freshGroup.id);
                      _loadGroups();
                    },
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showRenameGroupDialog(MeshGroup group) {
    final controller = TextEditingController(text: group.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: Text(
          'Rename Group',
          style: GoogleFonts.firaCode(
            color: AppTheme.purple,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.firaCode(
            color: AppTheme.textPrimary,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: 'New group name',
            hintStyle: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 14,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'CANCEL',
              style: GoogleFonts.firaCode(
                  color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await StorageService.renameGroup(group.id, newName);
                _loadGroups();
                Navigator.pop(ctx);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.purple),
            child: Text(
              'RENAME',
              style: GoogleFonts.firaCode(
                  fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClearMessages(String groupId, String groupName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.red),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: AppTheme.orange, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Clear Messages?',
                style: GoogleFonts.firaCode(
                  color: AppTheme.orange,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Delete all messages in "$groupName"?\nThis cannot be undone.',
          style: GoogleFonts.firaCode(
            color: AppTheme.textSecondary,
            fontSize: 11,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'CANCEL',
              style: GoogleFonts.firaCode(
                  color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await StorageService.clearGroupMessages(groupId);
              Navigator.pop(ctx);
              _loadGroups();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '> all messages cleared',
                    style: GoogleFonts.firaCode(fontSize: 12),
                  ),
                  backgroundColor: AppTheme.bgCard,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: Text(
              'DELETE ALL',
              style: GoogleFonts.firaCode(
                  fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteGroup(MeshGroup group) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.red),
        ),
        title: Row(
          children: [
            const Icon(Icons.delete_forever, color: AppTheme.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Delete Group?',
                style: GoogleFonts.firaCode(
                  color: AppTheme.red,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Delete "${group.name}" and all its messages?\nThis cannot be undone.',
          style: GoogleFonts.firaCode(
            color: AppTheme.textSecondary,
            fontSize: 11,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'CANCEL',
              style: GoogleFonts.firaCode(
                  color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await StorageService.clearGroupMessages(group.id);
              await StorageService.deleteGroup(group.id);
              Navigator.pop(ctx);
              _loadGroups();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '> group deleted',
                    style: GoogleFonts.firaCode(fontSize: 12),
                  ),
                  backgroundColor: AppTheme.bgCard,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: Text(
              'DELETE',
              style: GoogleFonts.firaCode(
                  fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
