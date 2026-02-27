import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../models/message.dart';
import '../services/storage_service.dart';
import '../services/mesh_controller.dart';

class ChatScreen extends StatefulWidget {
  final MeshController? meshController;
  final String? groupId;
  final String? groupName;
  final bool isGlobalChat;

  const ChatScreen({
    super.key,
    this.meshController,
    this.groupId,
    this.groupName,
    this.isGlobalChat = false,
  });

  bool get isGroupChat => groupId != null && groupId!.isNotEmpty;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  List<ChatMessage> _messages = [];
  String _username = '';
  StreamSubscription<ChatMessage>? _incomingSub;

  void _showTopNotification(
    String message, {
    Color color = AppTheme.cyan,
    IconData icon = Icons.bluetooth,
  }) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopNotification(
        message: message,
        color: color,
        icon: icon,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  @override
  void initState() {
    super.initState();
    _username = StorageService.getUsername() ?? 'anon';
    _loadMessages();

    // Listen for incoming Mesh messages
    _incomingSub = widget.meshController?.incomingMessages.listen((msg) {
      // Only reload if the message belongs to this chat
      if (widget.isGroupChat) {
        if (msg.groupId == widget.groupId) _loadMessages();
      } else {
        if (msg.groupId == null || msg.groupId!.isEmpty) _loadMessages();
      }
    });
    widget.meshController?.addListener(_onMeshUpdate);
  }

  void _onMeshUpdate() {
    if (mounted) setState(() {});
  }

  void _loadMessages() {
    setState(() {
      if (widget.isGroupChat) {
        _messages = StorageService.getMessages(groupId: widget.groupId);
      } else {
        _messages = StorageService.getMessages();
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    HapticFeedback.lightImpact();

    final message = ChatMessage(
      id: _uuid.v4(),
      from: _username,
      to: widget.isGroupChat ? widget.groupId! : 'broadcast',
      body: text,
      timestamp: DateTime.now(),
      ttl: 5,
      groupId: widget.groupId,
    );

    widget.meshController?.broadcastLocalMessage(message);
    _msgController.clear();
    _loadMessages();
  }

  // ── Edit / Delete ─────────────────────────────────────

  void _onLongPressMessage(ChatMessage msg) {
    if (msg.isDeleted) return; // Can't edit/delete already-deleted messages
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '> message options',
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.edit_outlined,
                color: AppTheme.cyan,
                size: 20,
              ),
              title: Text(
                'Edit message',
                style: GoogleFonts.firaCode(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showEditSheet(msg);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.delete_outline,
                color: AppTheme.red,
                size: 20,
              ),
              title: Text(
                'Delete message',
                style: GoogleFonts.firaCode(color: AppTheme.red, fontSize: 14),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showDeleteConfirm(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditSheet(ChatMessage msg) {
    final editController = TextEditingController(text: msg.body);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '> edit message',
              style: GoogleFonts.firaCode(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: editController,
              autofocus: true,
              maxLines: null,
              style: GoogleFonts.firaCode(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: AppTheme.bgDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.cyan),
                ),
                hintText: 'edit your message...',
                hintStyle: GoogleFonts.firaCode(
                  color: AppTheme.textMuted,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'CANCEL',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.cyan,
                    foregroundColor: AppTheme.bgDark,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () async {
                    final newBody = editController.text.trim();
                    if (newBody.isEmpty || newBody == msg.body) {
                      Navigator.pop(ctx);
                      return;
                    }
                    Navigator.pop(ctx);
                    await widget.meshController?.broadcastEdit(msg.id, newBody);
                    _loadMessages();
                  },
                  child: Text(
                    'SAVE',
                    style: GoogleFonts.firaCode(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirm(ChatMessage msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: Text(
          'Delete message?',
          style: GoogleFonts.firaCode(
            color: AppTheme.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'This will remove the message for you and all connected peers.',
          style: GoogleFonts.firaCode(
            color: AppTheme.textSecondary,
            fontSize: 12,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'CANCEL',
              style: GoogleFonts.firaCode(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.meshController?.broadcastDelete(msg.id);
              _loadMessages();
            },
            child: Text(
              'DELETE',
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

  @override
  void dispose() {
    _incomingSub?.cancel();
    widget.meshController?.removeListener(_onMeshUpdate);
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // Status bar
          _buildStatusBar(),

          // Messages list
          Expanded(
            child: _messages.isEmpty ? _buildEmptyState() : _buildMessageList(),
          ),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      leading: Navigator.of(context).canPop()
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            )
          : null,
      title: Row(
        children: [
          Icon(
            widget.isGroupChat ? Icons.group : Icons.terminal,
            color: widget.isGroupChat ? AppTheme.purple : AppTheme.green,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            widget.isGroupChat
                ? widget.groupName!
                : (widget.isGlobalChat ? 'Global Chat' : 'GitChat'),
            style: GoogleFonts.firaCode(
              color: widget.isGroupChat ? AppTheme.purple : AppTheme.green,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (widget.isGroupChat ? AppTheme.purple : AppTheme.green)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.isGroupChat ? 'GROUP' : 'GLOBAL',
              style: GoogleFonts.firaCode(
                color: widget.isGroupChat ? AppTheme.purple : AppTheme.green,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (widget.isGroupChat)
          IconButton(
            icon: const Icon(Icons.share, color: AppTheme.cyan),
            tooltip: 'Invite peers',
            onPressed: () {
              final group = StorageService.getGroup(widget.groupId!);
              if (group != null) {
                widget.meshController?.sendGroupInvite(group);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '> broadcasting group invite to nearby peers...',
                      style: GoogleFonts.firaCode(fontSize: 12),
                    ),
                    backgroundColor: AppTheme.bgCard,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        IconButton(
          icon: const Icon(Icons.bluetooth_searching, color: AppTheme.cyan),
          tooltip: 'Reconnect peers',
          onPressed: () async {
            final peers = widget.meshController?.connectedPeers.length ?? 0;
            if (peers > 0) {
              _showTopNotification(
                '$peers peer(s) connected',
                color: AppTheme.cyan,
                icon: Icons.bluetooth_connected,
              );
            } else {
              _showTopNotification(
                'Searching for peers...',
                color: AppTheme.orange,
                icon: Icons.bluetooth_searching,
              );
              widget.meshController?.stopMesh();
              await Future.delayed(const Duration(milliseconds: 500));
              await widget.meshController?.startMesh();
            }
          },
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 1)),
      ),
      child: Row(
        children: [
          // Online indicator
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppTheme.green,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.green,
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
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Icon(
            Icons.wifi_tethering,
            size: 14,
            color: (widget.meshController?.connectedPeers.length ?? 0) > 0
                ? AppTheme.cyan
                : AppTheme.textMuted,
          ),
          const SizedBox(width: 4),
          Text(
            '${widget.meshController?.connectedPeers.length ?? 0} peers',
            style: GoogleFonts.firaCode(
              color: (widget.meshController?.connectedPeers.length ?? 0) > 0
                  ? AppTheme.cyan
                  : AppTheme.textMuted,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_messages.length} msgs',
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
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: AppTheme.textMuted.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '> no messages yet',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'type something to broadcast',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted.withValues(alpha: 0.6),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final isMe = msg.from == _username;
        final showHeader = index == 0 || _messages[index - 1].from != msg.from;

        return Padding(
          padding: EdgeInsets.only(top: showHeader ? 12 : 2),
          child: _buildMessageBubble(msg, isMe, showHeader),
        );
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isMe, bool showHeader) {
    final isDeleted = msg.isDeleted;
    final isEdited = msg.isEdited && !isDeleted;

    return GestureDetector(
      onLongPress: isMe ? () => _onLongPressMessage(msg) : null,
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (showHeader)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isMe ? 'you' : '@${msg.from}',
                        style: GoogleFonts.firaCode(
                          color: isMe ? AppTheme.green : AppTheme.cyan,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(msg.timestamp),
                        style: GoogleFonts.firaCode(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                        ),
                      ),
                      if (isEdited) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(edited)',
                          style: GoogleFonts.firaCode(
                            color: AppTheme.textMuted,
                            fontSize: 9,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                      if (msg.isRelayed) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.repeat,
                          size: 10,
                          color: AppTheme.orange,
                        ),
                      ],
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDeleted
                      ? AppTheme.bgCard
                      : isMe
                      ? AppTheme.green.withValues(alpha: 0.12)
                      : AppTheme.bgCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDeleted
                        ? AppTheme.border.withValues(alpha: 0.4)
                        : isMe
                        ? AppTheme.green.withValues(alpha: 0.3)
                        : AppTheme.border,
                  ),
                ),
                child: isDeleted
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.delete_outline,
                            size: 13,
                            color: AppTheme.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Message deleted',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        msg.body,
                        style: GoogleFonts.firaCode(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(top: BorderSide(color: AppTheme.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
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
                controller: _msgController,
                style: GoogleFonts.firaCode(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: widget.isGroupChat
                      ? 'message ${widget.groupName}...'
                      : 'message global chat...',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintStyle: GoogleFonts.firaCode(
                    color: AppTheme.textMuted,
                    fontSize: 14,
                  ),
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
                onSubmitted: (_) => _sendMessage(),
                textInputAction: TextInputAction.send,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sendMessage,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.green,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.green.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.send_rounded,
                  color: AppTheme.bgDark,
                  size: 18,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ── Top Notification Overlay ─────────────────────────────────────────────────

class _TopNotification extends StatefulWidget {
  final String message;
  final Color color;
  final IconData icon;
  final VoidCallback onDone;

  const _TopNotification({
    required this.message,
    required this.color,
    required this.icon,
    required this.onDone,
  });

  @override
  State<_TopNotification> createState() => _TopNotificationState();
}

class _TopNotificationState extends State<_TopNotification>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

    _ctrl.forward();

    // Auto-dismiss after 2.5s
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        _ctrl.reverse().then((_) => widget.onDone());
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: widget.color, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.2),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: widget.color, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    widget.message,
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
