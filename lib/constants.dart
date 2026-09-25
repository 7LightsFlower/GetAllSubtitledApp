// constants.dart

import 'package:flutter/foundation.dart' show kIsWeb;
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:asr_live_translator/models/language_config.dart';

// ─── App title ──────────────────────────────────────────────────
const String appTitle = 'Subtitles in many languages';

// ─── Environment mode ─────────────────────────────────────────
// Kept for anything that still reads it. The backend URLs below no
// longer depend on this flag — they follow the browser's hostname,
// so `flutter run -d chrome` automatically talks to localhost:5000
// and a build served by Nginx automatically talks to the public URL.
const bool isDevelopment = false;

/// True when the app is running in a browser on localhost / 127.0.0.1,
/// or when it is not running on the web at all (native builds default
/// to dev so a stray mobile build doesn't hit the production server).
bool get runningOnLocalhost =>
    !kIsWeb ||
    html.window.location.hostname == 'localhost' ||
    html.window.location.hostname == '127.0.0.1';

// ─── Public web host ───────────────────────────────────────────
/// Public URL where the web app is hosted (frontend, i.e. the browser
/// origin). Used only for display / OAuth redirects, NOT as an API base.
const String publicServerUrl = 'https://get-all-subtitled.isl.iar.kit.edu';

// ─── Internal backend server (video processing + Dex OAuth) ────
// Options the user may pick from. No trailing slash.
const List<String> internalServerOptions = <String>[
  'https://lt2srv-sscherrer.isl.iar.kit.edu',
  'https://lecture-translator.kit.edu',
  'https://lt2srv-backup.iar.kit.edu',
];

const String defaultInternalServerUrl =
    'https://lt2srv-sscherrer.isl.iar.kit.edu';

const Map<String, String> internalServerLabels = {
  'https://lt2srv-sscherrer.isl.iar.kit.edu':
      'lt2srv-sscherrer (Default for now)',
  'https://lecture-translator.kit.edu': 'LT Main',
  'https://lt2srv-backup.iar.kit.edu': 'LT Backup',
};

String internalServerUrl = defaultInternalServerUrl;

// ─── Flask backend base ────────────────────────────────────────
// One source of truth. Both names resolve to the same value; keep
// them because call sites already reference each separately.
//
//   localhost / 127.0.0.1  → http://localhost:5000
//   anything else          → https://get-all-subtitled.isl.iar.kit.edu
//
// Because the value is picked at runtime, these must be `final`,
// not `const`. If any call site wraps them inside a `const`
// expression (e.g. `const Uri u = Uri.parse(authBaseUrl)`), that
// call site will need to become `final` too.
const String _devBackendUrl = 'http://localhost:5000';
const String _prodBackendUrl = 'https://get-all-subtitled.isl.iar.kit.edu';

final String authBaseUrl =
    runningOnLocalhost ? _devBackendUrl : _prodBackendUrl;

final String flaskServerUrl =
    runningOnLocalhost ? _devBackendUrl : _prodBackendUrl;

String get videoApiBaseUrl => internalServerUrl;

// ─── Internal server credentials (for auto-login) ─────────────
const String internalEmail = 'admin@example.com';
const String internalPassword = 'YourActualPassword123';

// ─── Dummy credentials for testing ────────────────────────────
const String dummyEmail = 'testuser@example.com';
const String dummyPassword = 'YourSecurePassword123';

// ─── Dex OAuth 2.0 Configuration ──────────────────────────────
const String dexClientId = 'traefik-forward-auth';
const String dexClientSecret = 'YourSecretKeyHere';
const List<String> dexScopes = ['openid', 'profile', 'email'];

String get dexIssuer => '$internalServerUrl/dex';

final String dexRedirectUri = runningOnLocalhost
    ? 'http://localhost:8080/'
    : '$publicServerUrl/';

// ─── Language names ────────────────────────────────────────────
//
// The code → name map lives in assets/languages.json and is loaded
// at startup by LanguageConfig.load() (see main.dart). Do not edit
// the map here — edit assets/languages.json instead.
//
// `languageNamesByCode` used to be a `const` map. It is now a
// getter backed by LanguageConfig.names, which is populated once
// the asset has been read.
Map<String, String> get languageNamesByCode => LanguageConfig.names;

// Reverse lookup cache, built lazily from languageNamesByCode.
// Invalidated by refreshLanguageConstants() after the asset loads.
Map<String, String>? _languageCodesByNameCache;

Map<String, String> get _languageCodesByName {
  final cached = _languageCodesByNameCache;
  if (cached != null) return cached;
  final built = {
    for (final e in languageNamesByCode.entries)
      e.value.toLowerCase(): e.key,
  };
  _languageCodesByNameCache = built;
  return built;
}

/// Call once after `await LanguageConfig.load()` so the reverse
/// lookup is rebuilt from the freshly-loaded names.
void refreshLanguageConstants() {
  _languageCodesByNameCache = null;
}

/// Resolve any language label to a full, human-readable name.
///
///   "English"                    -> "English"
///   "de"                         -> "German"
///   "Translation (Language de)"  -> "German"
///   "Translation (German)"       -> "German"
///   "Original ASR (English)"     -> "English"
///   "Original ASR (German)"      -> "German"
///   "Structured (English)"       -> "English"
///   "asr:de"                     -> "German"
///   ""                           -> ""
String resolveLanguageName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return trimmed;

  final lower = trimmed.toLowerCase();

  // ── Special case: any "Original ASR" transcript label collapses to a
  //    single clean name. Catches all of these raw forms:
  //      "Original ASR"
  //      "Original ASR (English)"
  //      "Original ASR - Language Transcript"
  //      "Transcript (Original ASR - Language Transcript)"
  //      "Transcript"
  if (lower.contains('original asr') || lower.startsWith('transcript')) {
    return 'Transcript';
  }

  // 1. Bare code or bare full name
  if (languageNamesByCode.containsKey(lower)) {
    return languageNamesByCode[lower]!;
  }
  if (_languageCodesByName.containsKey(lower)) return trimmed;

  // 2. Whatever is inside parentheses
  final paren = RegExp(r'\(([^)]+)\)').firstMatch(trimmed);
  if (paren != null) {
    var candidate = paren.group(1)!.trim();
    if (candidate.toLowerCase().startsWith('language ')) {
      candidate = candidate.substring('language '.length).trim();
    }
    final candLower = candidate.toLowerCase();
    if (languageNamesByCode.containsKey(candLower)) {
      return languageNamesByCode[candLower]!;
    }
    if (_languageCodesByName.containsKey(candLower)) {
      return candidate;
    }
  }

  // 3. A 2-letter code after a separator: "asr:de", "en-ASR", "x_en"
  final codeMatch =
      RegExp(r'[\s:\-_]([a-zA-Z]{2})\b').firstMatch(trimmed);
  if (codeMatch != null) {
    final code = codeMatch.group(1)!.toLowerCase();
    final name = languageNamesByCode[code];
    if (name != null) return name;
  }

  // 4. Any full language name appearing as a substring
  for (final entry in _languageCodesByName.entries) {
    if (lower.contains(entry.key)) {
      return languageNamesByCode[entry.value]!;
    }
  }

  return trimmed;
}
