// internal_auth_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart'; // for kDebugMode
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/constants.dart';

class InternalAuthService {
  static const String _tokenKey = 'internal_auth_token';

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static Future<bool> loginInternal() async {
    try {
      if (kDebugMode) {
        print('🔐 Attempting internal login to: $videoApiBaseUrl/login');
        print('📧 Email: $internalEmail');
        print('🔑 Password: ${'*' * internalPassword.length}');
      }

      final response = await http.post(
        Uri.parse('$videoApiBaseUrl/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'email': internalEmail,
          'password': internalPassword,
        },
      );

      if (kDebugMode) {
        print('📡 Response status: ${response.statusCode}');
        print('📄 Response body: ${response.body}');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        if (token != null) {
          await saveToken(token);
          if (kDebugMode) print('✅ Internal login successful, token saved.');
          return true;
        } else {
          if (kDebugMode) print('❌ No token in response.');
          return false;
        }
      } else {
        if (kDebugMode) print('❌ Login failed with status ${response.statusCode}');
        return false;
      }
    } catch (e) {
      if (kDebugMode) print('❌ Internal login error: $e');
      return false;
    }
  }
}