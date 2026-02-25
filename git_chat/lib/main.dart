import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'services/storage_service.dart';
import 'services/ble_service.dart';
import 'services/mesh_service.dart';
import 'screens/onboarding_screen.dart';
import 'screens/chat_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.bgDark,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  await StorageService.init();
  final hasUser = StorageService.getUsername() != null;

  runApp(BitChatApp(showOnboarding: !hasUser));
}

class BitChatApp extends StatefulWidget {
  final bool showOnboarding;

  const BitChatApp({super.key, required this.showOnboarding});

  @override
  State<BitChatApp> createState() => _BitChatAppState();
}

class _BitChatAppState extends State<BitChatApp> {
  late final BLEService _bleService;
  late final MeshService _meshService;

  @override
  void initState() {
    super.initState();
    _bleService = BLEService();
    _meshService = MeshService(_bleService);
  }

  @override
  void dispose() {
    _meshService.dispose();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BitChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: widget.showOnboarding
          ? const OnboardingScreen()
          : ChatScreen(bleService: _bleService),
    );
  }
}
