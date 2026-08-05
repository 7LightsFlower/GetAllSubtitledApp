// lib/main.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/screens/login_screen.dart';
import 'package:asr_live_translator/screens/register_screen.dart';
import 'package:asr_live_translator/screens/forgot_password_screen.dart';
import 'package:asr_live_translator/screens/working_screen.dart';
import 'package:asr_live_translator/constants.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/forgot_password': (context) => const ForgotPasswordScreen(),
        '/working': (context) => const WorkingScreen(),
      },
    );
  }
}