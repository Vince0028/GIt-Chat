import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'services/storage_service.dart';
import 'services/mesh_controller.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_screen.dart';

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

  runApp(GitChatApp(showOnboarding: !hasUser));
}

class GitChatApp extends StatefulWidget {
  final bool showOnboarding;

  const GitChatApp({super.key, required this.showOnboarding});

  @override
  State<GitChatApp> createState() => _GitChatAppState();
}

class _GitChatAppState extends State<GitChatApp> {
  late final MeshController _meshController;

  @override
  void initState() {
    super.initState();
    _meshController = MeshController();

    // Auto-start the mesh when the app launches (if user has onboarded)
    if (!widget.showOnboarding) {
      _startMeshNetwork();
    }
  }

  Future<void> _startMeshNetwork() async {
    await Future.delayed(const Duration(milliseconds: 500));
    await _meshController.startMesh();
  }

  @override
  void dispose() {
    _meshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GitChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: widget.showOnboarding
          ? OnboardingScreen(
              onComplete: _startMeshNetwork,
              meshController: _meshController,
            )
          : HomeScreen(meshController: _meshController),
    );
  }
}
