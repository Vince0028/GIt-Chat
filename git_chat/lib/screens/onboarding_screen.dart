import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/storage_service.dart';
import 'chat_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  late AnimationController _animController;
  late Animation<double> _fadeIn;
  bool _showCursor = true;
  String _typedPrefix = '';
  int _prefixIndex = 0;
  final String _prefix = '> initializing bitchat...';

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _fadeIn = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _startTypingEffect();

    // Blinking cursor
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 530));
      if (!mounted) return false;
      setState(() => _showCursor = !_showCursor);
      return true;
    });
  }

  void _startTypingEffect() async {
    await Future.delayed(const Duration(milliseconds: 400));
    for (int i = 0; i <= _prefix.length; i++) {
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 35));
      setState(() {
        _prefixIndex = i;
        _typedPrefix = _prefix.substring(0, i);
      });
    }
    await Future.delayed(const Duration(milliseconds: 300));
    _animController.forward();
  }

  void _submit() {
    final username = _controller.text.trim();
    if (username.isEmpty) return;

    HapticFeedback.mediumImpact();
    StorageService.saveUsername(username);

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, animation, secondaryAnimation) => const ChatScreen(),
        transitionsBuilder: (_, anim, secondaryAnim, child) {
          return FadeTransition(opacity: anim, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),

              // ASCII art logo
              Text(
                '╔══════════════════╗\n'
                '║    BIT  CHAT     ║\n'
                '╚══════════════════╝',
                style: GoogleFonts.firaCode(
                  color: AppTheme.green,
                  fontSize: 14,
                  height: 1.3,
                ),
              ),

              const SizedBox(height: 24),

              // Typing effect
              Row(
                children: [
                  Text(
                    _typedPrefix,
                    style: GoogleFonts.firaCode(
                      color: AppTheme.cyan,
                      fontSize: 13,
                    ),
                  ),
                  if (_prefixIndex < _prefix.length)
                    Text(
                      _showCursor ? '█' : ' ',
                      style: GoogleFonts.firaCode(
                        color: AppTheme.green,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 32),

              // Username input (appears after typing animation)
              FadeTransition(
                opacity: _fadeIn,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '> enter your callsign:',
                      style: GoogleFonts.firaCode(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),

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
                            controller: _controller,
                            focusNode: _focusNode,
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textPrimary,
                              fontSize: 16,
                            ),
                            decoration: InputDecoration(
                              hintText: 'your_name',
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              hintStyle: GoogleFonts.firaCode(
                                color: AppTheme.textMuted,
                                fontSize: 16,
                              ),
                            ),
                            onSubmitted: (_) => _submit(),
                            textInputAction: TextInputAction.go,
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: AppTheme.border, height: 1),
                    const SizedBox(height: 28),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submit,
                        icon: const Icon(Icons.terminal, size: 18),
                        label: const Text('CONNECT'),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Info text
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.bluetooth,
                                color: AppTheme.cyan,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'MESH NETWORK',
                                style: GoogleFonts.firaCode(
                                  color: AppTheme.cyan,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Messages hop through nearby devices\nusing Bluetooth. No internet needed.',
                            style: GoogleFonts.firaCode(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Version footer
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    'v1.0.0 • ble mesh protocol',
                    style: GoogleFonts.firaCode(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
