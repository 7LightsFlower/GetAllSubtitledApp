// lib/main.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/screens/login_screen.dart';
import 'package:asr_live_translator/screens/register_screen.dart';
import 'package:asr_live_translator/screens/forgot_password_screen.dart';
import 'package:asr_live_translator/screens/working_screen.dart';
import 'package:asr_live_translator/screens/splash_screen.dart';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';

Future<void> main() async {
    WidgetsFlutterBinding.ensureInitialized();

  await LanguageConfig.load();
  refreshLanguageConstants();
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      initialRoute: '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/forgot_password': (context) => const ForgotPasswordScreen(),
        '/working': (context) => const WorkingScreen(),
      },
    );
  }
}