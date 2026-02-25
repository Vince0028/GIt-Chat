import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../models/message.dart';
import '../services/storage_service.dart';
import '../services/ble_service.dart';
import 'discovery_screen.dart';

class ChatScreen extends StatefulWidget {
  final BLEService? bleService;

  const ChatScreen({super.key, this.bleService});

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

  @override
  void initState() {
    super.initState();
    _username = StorageService.getUsername() ?? 'anon';
    _loadMessages();

    // Listen for incoming BLE messages
    _incomingSub = widget.bleService?.incomingMessages.listen((_) {
      _loadMessages();
    });
    widget.bleService?.addListener(_onBLEUpdate);
  }

  void _onBLEUpdate() {
    if (mounted) setState(() {});
  }

  void _loadMessages() {
    setState(() {
      _messages = StorageService.getMessages();
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
      to: 'broadcast', // Public room for now
      body: text,
      timestamp: DateTime.now(),
      ttl: 3,
    );

    StorageService.saveMessage(message);

    // Also broadcast over BLE
    widget.bleService?.broadcastMessage(message);

    _msgController.clear();
    _loadMessages();
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    widget.bleService?.removeListener(_onBLEUpdate);
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
      title: Row(
        children: [
          const Icon(Icons.terminal, color: AppTheme.green, size: 20),
          const SizedBox(width: 8),
          Text(
            'BitChat',
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
        IconButton(
          icon: const Icon(Icons.bluetooth_searching, color: AppTheme.cyan),
          tooltip: 'Discover Peers',
          onPressed: () {
            if (widget.bleService != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DiscoveryScreen(bleService: widget.bleService!),
                ),
              );
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
            Icons.bluetooth,
            size: 14,
            color: (widget.bleService?.connectedPeerCount ?? 0) > 0
                ? AppTheme.cyan
                : AppTheme.textMuted,
          ),
          const SizedBox(width: 4),
          Text(
            '${widget.bleService?.connectedPeerCount ?? 0} peers',
            style: GoogleFonts.firaCode(
              color: (widget.bleService?.connectedPeerCount ?? 0) > 0
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
                    if (msg.isRelayed) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.repeat, size: 10, color: AppTheme.orange),
                    ],
                  ],
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
                  hintText: 'broadcast message...',
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
