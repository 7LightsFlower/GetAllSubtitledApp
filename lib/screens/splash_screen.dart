// lib/screens/splash_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html if (dart.library.html) '';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/screens/login_screen.dart';
import 'package:asr_live_translator/screens/working_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _handleOAuthCallback();
  }

  Future<void> _handleOAuthCallback() async {
    // 1. Handle OAuth redirect callback (web only)
    if (kIsWeb) {
      final uri = Uri.parse(html.window.location.href);
      final code = uri.queryParameters['code'];
      if (code != null) {
        final success = await InternalAuthService.handleOAuthCallback();
        if (success && mounted) {
          // Token stored – go to working screen
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const WorkingScreen()),
            );
          }
          return;
        }
        // If exchange failed, remove the code and go to login
        html.window.history.replaceState(
          {},
          '',
          uri.replace(queryParameters: {}).toString(),
        );
      }
    }

    // 2. Check if we already have a valid token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('internal_access_token');
    if (token != null && mounted) {
      // Optionally verify expiry? For now, assume valid.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const WorkingScreen()),
      );
    } else if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Authenticating...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}