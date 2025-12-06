import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tele_gallery/core/services/permission_service.dart';
import 'package:tele_gallery/features/auth/screens/login_screen.dart';
import 'package:tele_gallery/features/home/screens/home_screen.dart';
import 'package:tele_gallery/features/auth/providers/auth_provider.dart';
import 'package:tele_gallery/shared/models/cloud_media_item.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();

  // Register adapters
  Hive.registerAdapter(MediaTypeAdapter());
  Hive.registerAdapter(UploadStatusAdapter());
  Hive.registerAdapter(CloudMediaItemAdapter());

  // Open boxes
  await Hive.openBox<CloudMediaItem>('cloud_media');

  // Request storage permissions early
  await PermissionService.requestStoragePermissions();

  runApp(const ProviderScope(child: VoidApp()));
}

class VoidApp extends StatelessWidget {
  const VoidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Void',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark, // Dark mode by default for "Void" theme
        ),
        useMaterial3: true,
      ),
      home: const AuthWrapper(),
    );
  }
}

/// Wrapper that shows login or home based on auth state
class AuthWrapper extends ConsumerStatefulWidget {
  const AuthWrapper({super.key});

  @override
  ConsumerState<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends ConsumerState<AuthWrapper> {
  // We still need to check permissions on init
  bool _permissionsChecked = false;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndInit();
  }

  Future<void> _checkPermissionsAndInit() async {
    final hasPermissions = await PermissionService.hasStoragePermissions();
    if (!hasPermissions) {
      final granted = await PermissionService.requestStoragePermissions();
      if (!granted) {
        // Handle permission denial if needed, or just stay on loading/error
        // For now, let's proceed to allow retry in the UI builder if we want,
        // but here we just mark checked.
      }
    }

    final authService = ref.read(telegramAuthServiceProvider);

    // Trigger init and immediately ask TDLib for the current auth state so
    // we can skip the login UI when a valid session already exists.
    await authService.init();
    unawaited(authService.refreshAuthState());

    if (mounted) {
      setState(() {
        _permissionsChecked = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final authBaseValue = ref.watch(authStateProvider);

    return authBaseValue.when(
      data: (state) {
        if (state == 'ready') {
          return const HomeScreen();
        } else if (state == 'hot_restart_error') {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 60,
                      color: Colors.amber,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Connection Issue',
                      style: TextStyle(fontSize: 20),
                    ),
                    const SizedBox(height: 8),
                    const Text('Please restart the app completely.'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        ref.read(telegramAuthServiceProvider).init();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        } else {
          // 'wait_phone', 'wait_code', 'wait_password', 'closed', etc.
          return const LoginScreen();
        }
      },
      error: (e, st) => Scaffold(body: Center(child: Text('Error: $e'))),
      loading: () => const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to Telegram...'),
            ],
          ),
        ),
      ),
    );
  }
}
