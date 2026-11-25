import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'data/services/vault_lifecycle_guard.dart';
import 'data/services/vault_providers.dart';
import 'features/gallery/export_dialog.dart';
import 'features/gallery/gallery_screen.dart';
import 'features/gallery/media_viewer_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/setup/channel_select_screen.dart';
import 'features/setup/recovery_phrase_screen.dart';
import 'features/setup/setup_password_screen.dart';
import 'features/setup/telegram_login_screen.dart';
import 'features/splash/splash_screen.dart';
import 'features/unlock/recover_screen.dart';
import 'features/unlock/unlock_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void _logUnhandledError(String source, Object error, StackTrace? stackTrace) {
  if (kDebugMode) {
    debugPrint('[Pkrypt][$source] Unhandled error: $error');
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Catch Flutter framework / widget build errors
      FlutterError.onError = (FlutterErrorDetails details) {
        if (kDebugMode) {
          FlutterError.presentError(details);
        } else {
          _logUnhandledError('FlutterError', details.exception, details.stack);
        }
      };

      // Catch uncaught async / platform errors outside Flutter widgets
      WidgetsBinding.instance.platformDispatcher.onError =
          (Object error, StackTrace stack) {
        _logUnhandledError('PlatformDispatcher', error, stack);
        return true;
      };

      // Replace release-mode grey crash box with a clean dark fallback
      ErrorWidget.builder = (FlutterErrorDetails details) {
        if (kDebugMode) {
          return ErrorWidget(details.exception);
        }
        return const _InlineErrorFallback();
      };

      // Full edge-to-edge immersive display
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      // Transparent status + nav bars with light icons
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ));

      await _bootApp();
    },
    (Object error, StackTrace stackTrace) {
      _logUnhandledError('Zone', error, stackTrace);
    },
  );
}

Future<void> _bootApp() async {
  try {
    final vaultController = await createVaultController();

    runApp(
      ProviderScope(
        overrides: [
          vaultControllerProvider.overrideWith((ref) => vaultController),
        ],
        child: const VaultGalleryApp(),
      ),
    );
  } catch (error, stackTrace) {
    _logUnhandledError('Startup', error, stackTrace);
    runApp(const _StartupErrorApp(onRetry: _bootApp));
  }
}

class VaultGalleryApp extends StatelessWidget {
  const VaultGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return VaultLifecycleGuard(
      navigatorKey: rootNavigatorKey,
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        title: 'Pkrypt',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0A0A0F),
          useMaterial3: true,
        ),
        initialRoute: '/splash',
        routes: {
          '/splash': (context) => const SplashScreen(),
          '/setup': (context) => const SetupPasswordScreen(),
          '/recovery': (context) => const RecoveryPhraseScreen(
                phrase:
                    'apple banana cherry date elder fig grape honey iris jam kiwi lemon',
                wipeCode: '!wipe9x7k2',
              ),
          '/telegram': (context) => const TelegramLoginScreen(),
          '/channel_select': (context) => const ChannelSelectScreen(step: 0),
          '/unlock': (context) => const UnlockScreen(),
          '/gallery': (context) => const GalleryScreen(),
          '/settings': (context) => const SettingsScreen(),
          '/recover': (context) => const RecoverScreen(),
          '/viewer': (context) => const MediaViewerScreen(
                initialIndex: 0,
                items: ['1', '2', '3'],
                isVideoMode: false,
              ),
          '/export_dialog': (context) => const Dialog(
                child: ExportWarningDialog(),
              ),
        },
      ),
    );
  }
}

class _InlineErrorFallback extends StatelessWidget {
  const _InlineErrorFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF14141C),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Colors.white54, size: 28),
          SizedBox(height: 6),
          Text(
            'Unable to render this item',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StartupErrorApp extends StatelessWidget {
  final Future<void> Function() onRetry;

  const _StartupErrorApp({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pkrypt',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: Colors.white70,
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pkrypt couldn’t start cleanly',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tap retry to reinitialize your local vault safely.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}