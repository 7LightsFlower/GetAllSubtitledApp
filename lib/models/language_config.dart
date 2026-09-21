// lib/models/language_config.dart

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// Centralized language configuration loaded from assets/languages.json.
///
/// Call [LanguageConfig.load] once at startup (before runApp), then use
/// the static getters as before.
class LanguageConfig {
  LanguageConfig._();   // no instances

  static bool _loaded = false;

  // Canonical code -> name map, plus the three category code lists.
  static Map<String, String> _names = {};
  static List<String> _inputCodes = [];
  static List<String> _outputCodes = [];
  static List<String> _audioCodes = [];

  // Materialized maps for the public getters.
  static Map<String, String> _inputLanguages = {};
  static Map<String, String> _outputLanguages = {};
  static Map<String, String> _audioLanguages = {};
  static Map<String, String> _allLanguages = {};

  /// Read assets/languages.json and populate all maps.
  /// Safe to call more than once — the second call is a no-op.
  static Future<void> load() async {
    if (_loaded) return;

    final raw = await rootBundle.loadString('assets/languages.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;

    _names = Map<String, String>.from(data['names'] as Map);
    _inputCodes = List<String>.from(data['input'] as List);
    _outputCodes = List<String>.from(data['output'] as List);
    _audioCodes = List<String>.from(data['audio'] as List);

    Map<String, String> build(List<String> codes) => {
          for (final c in codes) c: _names[c] ?? c.toUpperCase(),
        };

    _inputLanguages = build(_inputCodes);
    _outputLanguages = build(_outputCodes);
    _audioLanguages = build(_audioCodes);

    _allLanguages = {
      ..._inputLanguages,
      ..._outputLanguages,
      ..._audioLanguages,
    };

    _loaded = true;
  }

  /// True once [load] has completed successfully.
  static bool get isLoaded => _loaded;

  // ─── Public API (same shape as before) ────────────────────────────

  static Map<String, String> get inputLanguages => _inputLanguages;
  static Map<String, String> get outputLanguages => _outputLanguages;
  static Map<String, String> get audioLanguages => _audioLanguages;
  static Map<String, String> get allLanguages => _allLanguages;
  static Map<String, String> get names => _names;

  static const Map<String, String> senderPrefixes = {
    'asr': 'Transcript (Original ASR - {language})',
    'mt': '{language} Translation',
    'textstructurer': 'Transcript (Structured - {language})',
    'saasr': 'Transcript (SAASR - {language})',
    'tts': '{language}',
  };

  static String getDisplayName(String code) =>
      _allLanguages[code] ??
      _inputLanguages[code] ??
      _outputLanguages[code] ??
      _audioLanguages[code] ??
      code.toUpperCase();

  static String getInputLanguageName(String code) =>
      _inputLanguages[code] ?? code.toUpperCase();

  static String getOutputLanguageName(String code) =>
      _outputLanguages[code] ?? code.toUpperCase();

  static String getAudioLanguageName(String code) =>
      _audioLanguages[code] ?? code.toUpperCase();

  static List<String> getSortedInputLanguages() {
    final codes = _inputLanguages.keys.toList();
    codes.sort((a, b) => _inputLanguages[a]!.compareTo(_inputLanguages[b]!));
    return codes;
  }

  static List<String> getSortedOutputLanguages() {
    final codes = _outputLanguages.keys.toList();
    codes.sort((a, b) => _outputLanguages[a]!.compareTo(_outputLanguages[b]!));
    return codes;
  }

  static List<String> getSortedAudioLanguages() {
    final codes = _audioLanguages.keys.toList();
    codes.sort((a, b) => _audioLanguages[a]!.compareTo(_audioLanguages[b]!));
    return codes;
  }

  static List<String> getSortedLanguageNames() {
    final names = _allLanguages.values.toList()..sort();
    return names;
  }

  static bool isInputLanguage(String code) => _inputLanguages.containsKey(code);
  static bool isOutputLanguage(String code) => _outputLanguages.containsKey(code);
  static bool isAudioLanguage(String code) => _audioLanguages.containsKey(code);
  static bool isSupported(String code) => _allLanguages.containsKey(code);

  // ─── Dynamic helpers (unchanged logic) ────────────────────────────

  static Map<String, String> buildLanguageMap({
    required List<String> languages,
    Map<String, String>? senderMapping,
  }) {
    final Map<String, String> result = {};
    for (int i = 0; i < languages.length; i++) {
      result[i.toString()] = getDisplayName(languages[i]);
    }
    if (senderMapping != null) {
      for (final entry in senderMapping.entries) {
        result[entry.key] = getDisplayName(entry.value);
      }
    }
    return result;
  }

  static String getLanguageNameFromSender(
    String sender,
    Map<String, String> languageMap,
  ) {
    if (languageMap.containsKey(sender)) return languageMap[sender]!;

    for (final prefix in senderPrefixes.keys) {
      if (sender.startsWith('$prefix:')) {
        final id = sender.replaceFirst('$prefix:', '');
        final pattern = senderPrefixes[prefix]!;
        if (languageMap.containsKey(id)) {
          return pattern.replaceAll('{language}', languageMap[id]!);
        }
        if (_allLanguages.containsKey(id)) {
          return pattern.replaceAll('{language}', _allLanguages[id]!);
        }
        return pattern.replaceAll('{language}', id);
      }
    }

    for (final code in _allLanguages.keys) {
      if (sender.contains('_$code') || sender.contains(':$code')) {
        return getDisplayName(code);
      }
    }
    return sender;
  }

  static Map<String, String> parseSenderMapping(String htmlContent) {
    final Map<String, String> mapping = {};
    try {
      final m = RegExp(r'data-sender="([^"]+)"').firstMatch(htmlContent);
      if (m != null) {
        final raw = m.group(1)!.replaceAll('&quot;', '"');
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          mapping[e.key] = e.value.toString();
        }
      }
    } catch (_) {}
    return mapping;
  }

  static List<String> parseAvailableLanguages(String htmlContent) {
    final Set<String> languages = {};
    try {
      final m = RegExp(r'data-lang-name="([^"]+)"').firstMatch(htmlContent);
      if (m != null) {
        final raw = m.group(1)!.replaceAll('&quot;', '"');
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          final name = e.value.toString();
          if (!name.contains('Audio') && !name.contains('Correction')) {
            languages.add(name);
          }
        }
      }
    } catch (_) {}
    return languages.toList();
  }

  static Map<String, String> parseNumericLanguageMap(dynamic messagesData) {
    final Map<String, String> result = {};
    try {
      if (messagesData is List) {
        for (final item in messagesData) {
          if (item is List && item.length >= 2) {
            final id = item[0].toString();
            final msgStr = item[1];
            Map<String, dynamic>? msgData;
            if (msgStr is String) {
              msgData = jsonDecode(msgStr) as Map<String, dynamic>;
            } else if (msgStr is Map) {
              msgData = Map<String, dynamic>.from(msgStr);
            }
            if (msgData == null) continue;
            final sender = msgData['sender']?.toString() ?? '';
            if (sender.isNotEmpty) {
              final langName = _extractLanguageName(sender, id);
              if (langName.isNotEmpty) {
                result[id] = langName;
                result[sender] = langName;
              }
            }
          }
        }
      }
    } catch (_) {}
    return result;
  }

  static String _extractLanguageName(String sender, String id) {
    for (final prefix in senderPrefixes.keys) {
      if (sender.startsWith('$prefix:')) {
        final langId = sender.replaceFirst('$prefix:', '');
        if (_allLanguages.containsKey(langId)) return _allLanguages[langId]!;
        break;
      }
    }
    for (final code in _allLanguages.keys) {
      if (sender.contains('_$code') || sender.contains(':$code')) {
        return _allLanguages[code]!;
      }
    }
    return 'Language $id';
  }

  static String? getNumericIdForCode(
      String code, Map<String, String> languageMap) {
    for (final entry in languageMap.entries) {
      if (entry.value == code || entry.value == getDisplayName(code)) {
        return entry.key;
      }
    }
    return null;
  }
}