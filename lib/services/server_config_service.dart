// services/server_config_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/constants.dart';

/// Result of an `addCustomServer` call.
enum AddResult {
  /// Not present before, saved successfully.
  added,

  /// Already in the built-in list or the custom list.
  duplicate,

  /// Failed the host validator (or a storage write failed).
  invalid,
}

/// Persists the user's choice of internal server across app restarts,
/// and remembers any custom `lt2srv-XXXX` hosts the user has typed in.
class ServerConfigService {
  static const String _selectedKey = 'internal_server_url';
  static const String _customKey = 'internal_server_custom_urls';

  static bool _loaded = false;
  static List<String> _custom = <String>[];

  /// User-added servers, in the order they were added. Read-only.
  static List<String> get customServers => List.unmodifiable(_custom);

  /// Every selectable server: built-ins first, then user-added ones.
  static List<String> get allServers => <String>[
        ...internalServerOptions,
        ..._custom,
      ];

  /// True when [url] is one of the built-in entries.
  static bool isBuiltIn(String url) => internalServerOptions.contains(url);

  // ── Load ─────────────────────────────────────────────────────────

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();

      final saved = prefs.getString(_selectedKey);
      if (saved != null && isAllowedInternalServer(saved)) {
        internalServerUrl = saved;
      } else {
        internalServerUrl = defaultInternalServerUrl;
      }

      final raw = prefs.getStringList(_customKey) ?? const <String>[];
      _custom = raw.where(isAllowedInternalServer).toList(growable: true);
    } catch (e) {
      debugPrint('ServerConfigService.load error: $e');
      internalServerUrl = defaultInternalServerUrl;
      _custom = <String>[];
    } finally {
      _loaded = true;
    }
  }

  // ── Switch the active server ─────────────────────────────────────

  static Future<void> setServer(String url) async {
    final normalised = _normalise(url);
    if (!isAllowedInternalServer(normalised)) {
      throw ArgumentError('Unknown server URL: $url');
    }

    internalServerUrl = normalised;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedKey, normalised);
    } catch (e) {
      debugPrint('ServerConfigService.setServer error: $e');
    }
  }

  // ── Custom server management ─────────────────────────────────────

  static Future<AddResult> addCustomServer(String url) async {
    final normalised = _normalise(url);
    if (!isAllowedInternalServer(normalised)) return AddResult.invalid;
    if (allServers.contains(normalised)) return AddResult.duplicate;

    _custom.add(normalised);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_customKey, _custom);
    } catch (e) {
      _custom.remove(normalised);
      debugPrint('ServerConfigService.addCustomServer error: $e');
      return AddResult.invalid;
    }
    return AddResult.added;
  }

  static Future<void> removeCustomServer(String url) async {
    final normalised = _normalise(url);
    if (internalServerOptions.contains(normalised)) return;

    final removed = _custom.remove(normalised);
    if (!removed) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_customKey, _custom);
    } catch (e) {
      debugPrint('ServerConfigService.removeCustomServer error: $e');
    }

    if (internalServerUrl == normalised) {
      await setServer(defaultInternalServerUrl);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────

  static String _normalise(String url) {
    var u = url.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  static String get current => internalServerUrl;

  @visibleForTesting
  static void resetForTesting() {
    _loaded = false;
    _custom = <String>[];
    internalServerUrl = defaultInternalServerUrl;
  }
}