import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../models/message.dart';
import '../services/ble_service.dart';
import '../services/storage_service.dart';

class PeerChatScreen extends StatefulWidget {
  final BLEService bleService;
  final BLEPeer peer;

  const PeerChatScreen({
    super.key,
    required this.bleService,
    required this.peer,
  });

  @override
  State<PeerChatScreen> createState() => _PeerChatScreenState();
}

class _PeerChatScreenState extends State<PeerChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  List<ChatMessage> _messages = [];
  String _username = '';
  StreamSubscription<ChatMessage>? _incomingSub;

  @override
  void initState() {
    super.initState();
    _username = StorageService.getUsername() ?? 'anon';
    _loadMessages();

    // Listen for incoming messages from this peer
    _incomingSub = widget.bleService.incomingMessages.listen((msg) {
      if (msg.from == widget.peer.username ||
          msg.from == widget.peer.deviceId) {
        _loadMessages();
      }
    });
  }

  void _loadMessages() {
    final peerId = widget.peer.username ?? widget.peer.deviceId;
    setState(() {
      _messages = StorageService.getMessages(peerId: peerId);
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

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    final peerName = widget.peer.username ?? widget.peer.deviceId;
    final message = ChatMessage(
      id: _uuid.v4(),
      from: _username,
      to: peerName,
      body: text,
      timestamp: DateTime.now(),
      ttl: 3,
    );

    final sent = await widget.bleService.sendMessage(
      message,
      widget.peer.deviceId,
    );

    if (!sent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '> failed to send. peer may be out of range.',
            style: GoogleFonts.firaCode(fontSize: 12),
          ),
          backgroundColor: AppTheme.red.withValues(alpha: 0.2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _msgController.clear();
    _loadMessages();
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerName = widget.peer.username ?? widget.peer.deviceName;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: widget.peer.isConnected ? AppTheme.green : AppTheme.red,
                shape: BoxShape.circle,
                boxShadow: widget.peer.isConnected
                    ? [
                        BoxShadow(
                          color: AppTheme.green.withValues(alpha: 0.5),
                          blurRadius: 4,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '@$peerName',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    widget.peer.isConnected
                        ? 'connected • ${widget.peer.rssi} dBm'
                        : 'disconnected',
                    style: GoogleFonts.firaCode(
                      color: widget.peer.isConnected
                          ? AppTheme.green
                          : AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty ? _buildEmptyState() : _buildMessageList(),
          ),
          _buildInputBar(),
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
            size: 40,
            color: AppTheme.textMuted.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            '> start chatting over bluetooth',
            style: GoogleFonts.firaCode(
              color: AppTheme.textMuted,
              fontSize: 12,
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
          child: _buildBubble(msg, isMe, showHeader),
        );
      },
    );
  }

  Widget _buildBubble(ChatMessage msg, bool isMe, bool showHeader) {
    return Align(
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
                child: Text(
                  '${isMe ? "you" : "@${msg.from}"} • ${_fmt(msg.timestamp)}',
                  style: GoogleFonts.firaCode(
                    color: isMe ? AppTheme.green : AppTheme.cyan,
                    fontSize: 10,
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe
                    ? AppTheme.green.withValues(alpha: 0.12)
                    : AppTheme.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMe
                      ? AppTheme.green.withValues(alpha: 0.3)
                      : AppTheme.border,
                ),
              ),
              child: Text(
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
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(top: BorderSide(color: AppTheme.border)),
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
                  hintText: 'send to @${widget.peer.username ?? "peer"}...',
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

  String _fmt(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
