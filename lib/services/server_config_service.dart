// services/server_config_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/constants.dart';

/// Persists the user's choice of internal server across app restarts.
class ServerConfigService {
  static const String _prefKey = 'internal_server_url';
  static bool _loaded = false;

  /// Reads the saved server URL into the global [internalServerUrl].
  /// Safe to call multiple times (idempotent).
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null && internalServerOptions.contains(saved)) {
        internalServerUrl = saved;
      } else {
        internalServerUrl = defaultInternalServerUrl;
      }
    } catch (e) {
      if (kDebugMode) print('ServerConfigService.load error: $e');
      internalServerUrl = defaultInternalServerUrl;
    } finally {
      _loaded = true;
    }
  }

  /// Changes the active internal server and persists the choice.
  static Future<void> setServer(String url) async {
    if (!internalServerOptions.contains(url)) {
      throw ArgumentError('Unknown server URL: $url');
    }
    internalServerUrl = url;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, url);
    } catch (e) {
      if (kDebugMode) print('ServerConfigService.setServer error: $e');
    }
  }

  static String get current => internalServerUrl;
}