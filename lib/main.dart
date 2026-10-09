// lib/main.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/screens/login_screen.dart';
import 'package:asr_live_translator/screens/register_screen.dart';
import 'package:asr_live_translator/screens/forgot_password_screen.dart';
import 'package:asr_live_translator/screens/session_detail_screen.dart';
import 'package:asr_live_translator/screens/working_screen.dart';
import 'package:asr_live_translator/screens/splash_screen.dart';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';

Future<void> main() async {
    WidgetsFlutterBinding.ensureInitialized();

  await LanguageConfig.load();
  refreshLanguageConstants();
  debugPrint('authBaseUrl    = $authBaseUrl');
  debugPrint('flaskServerUrl = $flaskServerUrl');
  debugPrint('dexRedirectUri = $dexRedirectUri');
  debugPrint('isDevelopment  = $isDevelopment');
  
  runApp(const MyApp());

}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      initialRoute: '/splash',
      // `onGenerateRoute` is used instead of `routes:` because the
      // session-detail path carries a parameter (`:video_key`) that
      // the static `routes:` map cannot express.
      onGenerateRoute: (settings) {
        final name = settings.name ?? '/';

        // ── /session-detail/<video_key> ───────────────────────────
        // Matches a single path segment (no `/`, no query). The
        // video key is a UUID, but the regex is deliberately liberal
        // so a future change to the key format does not break the
        // route.
        final sessionDetail =
            RegExp(r'^/session-detail/([^/?#]+)').firstMatch(name);
        if (sessionDetail != null) {
          final videoKey =
              Uri.decodeComponent(sessionDetail.group(1)!);
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => LiveTranscriptScreen(videoKey: videoKey),
          );
        }

        // ── /working  and  /working/<email> ───────────────────────
        // `/working` alone is the anonymous fallback; the email
        // segment is informational, so both build the same screen.
        // Listing this before the static switch is what lets a
        // refresh on `/working/testuser%40example.com` land back
        // on the working screen instead of falling through.
        if (name == '/working' || name.startsWith('/working/')) {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => const WorkingScreen(),
          );
        }

        // ── Static routes ─────────────────────────────────────────
        switch (name) {
          case '/splash':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const SplashScreen(),
            );
          case '/login':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const LoginScreen(),
            );
          case '/register':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const RegisterScreen(),
            );
          case '/forgot_password':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const ForgotPasswordScreen(),
            );
          // NOTE: the `/working` case that used to live in this switch is
          // gone — it is now handled above, where it can also accept the
          // optional `/<email>` suffix.
        }

        // ── Static routes ─────────────────────────────────────────
        switch (name) {
          case '/splash':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const SplashScreen(),
            );
          case '/login':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const LoginScreen(),
            );
          case '/register':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const RegisterScreen(),
            );
          case '/forgot_password':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const ForgotPasswordScreen(),
            );
          case '/working':
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const WorkingScreen(),
            );
        }

        // Anything else: fall back to splash rather than crashing.
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const SplashScreen(),
        );
      },
    );
  }
}