// lib/models/language_config.dart

import 'dart:convert';

/// Centralized language configuration for the app using ISO 639-1 codes
class LanguageConfig {
  // ─── INPUT LANGUAGES ────────────────────────────────────────────────
  // Complete list of input languages from the server's HTML form
  static const Map<String, String> inputLanguages = {
    'af': 'Afrikaans',
    'sq': 'Albanian',
    'am': 'Amharic',
    'ar': 'Arabic',
    'hy': 'Armenian',
    'as': 'Assamese',
    'az': 'Azerbaijani',
    'bn': 'Bangla',
    'ba': 'Bashkir',
    'eu': 'Basque',
    'be': 'Belarusian',
    'bs': 'Bosnian',
    'br': 'Breton',
    'bg': 'Bulgarian',
    'my': 'Burmese',
    'yue': 'Cantonese',
    'ca': 'Catalan',
    'zh': 'Chinese',
    'hr': 'Croatian',
    'cs': 'Czech',
    'da': 'Danish',
    'nl': 'Dutch',
    'en': 'English',
    'et': 'Estonian',
    'fo': 'Faroese',
    'tl': 'Filipino',
    'fi': 'Finnish',
    'fr': 'French',
    'gl': 'Galician',
    'ka': 'Georgian',
    'de': 'German',
    'el': 'Greek',
    'gu': 'Gujarati',
    'ht': 'Haitian Creole',
    'ha': 'Hausa',
    'haw': 'Hawaiian',
    'he': 'Hebrew',
    'hi': 'Hindi',
    'hu': 'Hungarian',
    'is': 'Icelandic',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'jw': 'Javanese',
    'kn': 'Kannada',
    'kk': 'Kazakh',
    'km': 'Khmer',
    'ko': 'Korean',
    'lo': 'Lao',
    'la': 'Latin',
    'lv': 'Latvian',
    'ln': 'Lingala',
    'lt': 'Lithuanian',
    'lb': 'Luxembourgish',
    'mk': 'Macedonian',
    'mg': 'Malagasy',
    'ms': 'Malay',
    'ml': 'Malayalam',
    'mt': 'Maltese',
    'mr': 'Marathi',
    'mn': 'Mongolian',
    'mi': 'Māori',
    'ne': 'Nepali',
    'no': 'Norwegian',
    'nn': 'Norwegian Nynorsk',
    'oc': 'Occitan',
    'ps': 'Pashto',
    'fa': 'Persian',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'pa': 'Punjabi',
    'ro': 'Romanian',
    'ru': 'Russian',
    'sa': 'Sanskrit',
    'sr': 'Serbian',
    'sn': 'Shona',
    'sd': 'Sindhi',
    'si': 'Sinhala',
    'sk': 'Slovak',
    'sl': 'Slovenian',
    'so': 'Somali',
    'es': 'Spanish',
    'su': 'Sundanese',
    'sw': 'Swahili',
    'sv': 'Swedish',
    'tg': 'Tajik',
    'ta': 'Tamil',
    'tt': 'Tatar',
    'te': 'Telugu',
    'th': 'Thai',
    'bo': 'Tibetan',
    'tr': 'Turkish',
    'tk': 'Turkmen',
    'uk': 'Ukrainian',
    'ur': 'Urdu',
    'uz': 'Uzbek',
    'vi': 'Vietnamese',
    'cy': 'Welsh',
    'yi': 'Yiddish',
    'yo': 'Yoruba',
  };

  // ─── OUTPUT LANGUAGES (Translation) ──────────────────────────────
  // Complete list of output languages from the server's HTML form
  static const Map<String, String> outputLanguages = {
    'ar': 'Arabic',
    'bn': 'Bangla',
    'zh': 'Chinese',
    'zh_tw': 'Chinese (Taiwan)',
    'da': 'Danish',
    'nl': 'Dutch',
    'en': 'English',
    'fr': 'French',
    'de': 'German',
    'el': 'Greek',
    'hi': 'Hindi',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'fa': 'Persian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'es': 'Spanish',
    'ta': 'Tamil',
    'th': 'Thai',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'vi': 'Vietnamese',
  };

  // ─── AUDIO LANGUAGES (TTS) ────────────────────────────────────────
  // Complete list of audio languages from the server's HTML form
  static const Map<String, String> audioLanguages = {
    'ar': 'Arabic',
    'bn': 'Bangla',
    'zh': 'Chinese',
    'en': 'English',
    'tl': 'Filipino',
    'fr': 'French',
    'de': 'German',
    'hi': 'Hindi',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'fa': 'Persian',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'es': 'Spanish',
    'th': 'Thai',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'vi': 'Vietnamese',
  };

  // ─── COMBINED MAPS ────────────────────────────────────────────────
  // Combined map of all languages (computed at runtime to handle duplicates)
  static Map<String, String>? _allLanguagesCache;
  
  static Map<String, String> get allLanguages {
    _allLanguagesCache ??= {
      ...inputLanguages,
      ...outputLanguages,
      ...audioLanguages,
    };
    return _allLanguagesCache!;
  }

  // Map of sender prefixes to language name patterns
  static const Map<String, String> senderPrefixes = {
    'asr': 'Transcript (Original ASR - {language})',
    'mt': '{language} Translation',
    'textstructurer': 'Transcript (Structured - {language})',
    'saasr': 'Transcript (SAASR - {language})',
    'tts': '{language}',
  };

  // ─── GETTER METHODS ────────────────────────────────────────────────

  /// Get display name for a language code (checks all language maps)
  static String getDisplayName(String code) {
    return allLanguages[code] ?? 
           inputLanguages[code] ?? 
           outputLanguages[code] ?? 
           audioLanguages[code] ??
           code.toUpperCase();
  }

  /// Get input language display name
  static String getInputLanguageName(String code) {
    return inputLanguages[code] ?? code.toUpperCase();
  }

  /// Get output language display name
  static String getOutputLanguageName(String code) {
    return outputLanguages[code] ?? code.toUpperCase();
  }

  /// Get audio language display name
  static String getAudioLanguageName(String code) {
    return audioLanguages[code] ?? code.toUpperCase();
  }

  /// Get sorted input language codes
  static List<String> getSortedInputLanguages() {
    final codes = inputLanguages.keys.toList();
    codes.sort((a, b) => inputLanguages[a]!.compareTo(inputLanguages[b]!));
    return codes;
  }

  /// Get sorted output language codes
  static List<String> getSortedOutputLanguages() {
    final codes = outputLanguages.keys.toList();
    codes.sort((a, b) => outputLanguages[a]!.compareTo(outputLanguages[b]!));
    return codes;
  }

  /// Get sorted audio language codes
  static List<String> getSortedAudioLanguages() {
    final codes = audioLanguages.keys.toList();
    codes.sort((a, b) => audioLanguages[a]!.compareTo(audioLanguages[b]!));
    return codes;
  }

  /// Get all available language display names sorted (for reference)
  static List<String> getSortedLanguageNames() {
    final names = allLanguages.values.toList();
    names.sort();
    return names;
  }

  /// Check if a language code is supported in input languages
  static bool isInputLanguage(String code) {
    return inputLanguages.containsKey(code);
  }

  /// Check if a language code is supported in output languages
  static bool isOutputLanguage(String code) {
    return outputLanguages.containsKey(code);
  }

  /// Check if a language code is supported in audio languages
  static bool isAudioLanguage(String code) {
    return audioLanguages.containsKey(code);
  }

  /// Check if a language code is supported in any language list
  static bool isSupported(String code) {
    return allLanguages.containsKey(code);
  }

  // ─── DYNAMIC LANGUAGE MAPPING ─────────────────────────────────────

  /// Build a dynamic language map for a specific session
  static Map<String, String> buildLanguageMap({
    required List<String> languages,
    Map<String, String>? senderMapping,
  }) {
    final Map<String, String> result = {};

    // Map numeric IDs to language names
    for (int i = 0; i < languages.length; i++) {
      final code = languages[i];
      final name = getDisplayName(code);
      result[i.toString()] = name;
    }

    // Map sender strings to language names
    if (senderMapping != null) {
      for (final entry in senderMapping.entries) {
        final sender = entry.key;
        final code = entry.value;
        final name = getDisplayName(code);
        result[sender] = name;
      }
    }

    return result;
  }

  /// Get language name from a sender string using a dynamic map
  static String getLanguageNameFromSender(
    String sender,
    Map<String, String> languageMap,
  ) {
    // Check if we have a direct mapping
    if (languageMap.containsKey(sender)) {
      return languageMap[sender]!;
    }

    // Check if sender has a numeric ID that's in the map
    for (final prefix in senderPrefixes.keys) {
      if (sender.startsWith('$prefix:')) {
        final id = sender.replaceFirst('$prefix:', '');
        // Try to find the language name for this numeric ID
        if (languageMap.containsKey(id)) {
          final langName = languageMap[id]!;
          final pattern = senderPrefixes[prefix]!;
          return pattern.replaceAll('{language}', langName);
        }
        // If not found, check if it's an ISO code
        if (allLanguages.containsKey(id)) {
          final langName = allLanguages[id]!;
          final pattern = senderPrefixes[prefix]!;
          return pattern.replaceAll('{language}', langName);
        }
        // Fallback: use the ID as the language name
        final pattern = senderPrefixes[prefix]!;
        return pattern.replaceAll('{language}', id);
      }
    }

    // Try to extract ISO code from sender
    for (final code in allLanguages.keys) {
      if (sender.contains('_$code') || sender.contains(':$code')) {
        return getDisplayName(code);
      }
    }

    // If all else fails, return the sender
    return sender;
  }

  /// Parse sender-to-language mapping from HTML
  static Map<String, String> parseSenderMapping(String htmlContent) {
    final Map<String, String> mapping = {};
    
    try {
      // Look for data-sender attribute
      final RegExp senderRegex = RegExp(r'data-sender="([^"]+)"');
      final senderMatch = senderRegex.firstMatch(htmlContent);
      if (senderMatch != null) {
        final raw = senderMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        for (final entry in map.entries) {
          mapping[entry.key] = entry.value.toString();
        }
      }
    } catch (e) {
      // Ignore parsing errors
    }
    
    return mapping;
  }

  /// Parse language names from HTML
  static List<String> parseAvailableLanguages(String htmlContent) {
    final Set<String> languages = {};
    
    try {
      final RegExp langNameRegex = RegExp(r'data-lang-name="([^"]+)"');
      final langNameMatch = langNameRegex.firstMatch(htmlContent);
      if (langNameMatch != null) {
        final raw = langNameMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        for (final entry in map.entries) {
          final name = entry.value.toString();
          if (!name.contains('Audio') && !name.contains('Correction')) {
            languages.add(name);
          }
        }
      }
    } catch (e) {
      // Ignore parsing errors
    }
    
    return languages.toList();
  }

  /// Parse numeric language mapping from session data
  static Map<String, String> parseNumericLanguageMap(dynamic messagesData) {
    final Map<String, String> result = {};
    
    try {
      if (messagesData is List) {
        for (final item in messagesData) {
          if (item is List && item.length >= 2) {
            final id = item[0].toString();
            final msgStr = item[1];
            try {
              Map<String, dynamic> msgData;
              if (msgStr is String) {
                msgData = jsonDecode(msgStr);
              } else if (msgStr is Map) {
                msgData = Map<String, dynamic>.from(msgStr);
              } else {
                continue;
              }
              
              final sender = msgData['sender']?.toString() ?? '';
              // Store the mapping
              if (sender.isNotEmpty) {
                // Try to extract the language name
                final langName = _extractLanguageName(sender, id);
                if (langName.isNotEmpty) {
                  result[id] = langName;
                  result[sender] = langName;
                }
              }
            } catch (e) {
              // Skip invalid entries
            }
          }
        }
      }
    } catch (e) {
      // Ignore parsing errors
    }
    
    return result;
  }

  /// Helper method to extract language name from sender
  static String _extractLanguageName(String sender, String id) {
    // Check if we can extract from sender
    for (final prefix in senderPrefixes.keys) {
      if (sender.startsWith('$prefix:')) {
        final langId = sender.replaceFirst('$prefix:', '');
        // Check if langId is a known language code
        if (allLanguages.containsKey(langId)) {
          return allLanguages[langId]!;
        }
        break;
      }
    }
    
    // Check for language codes in sender
    for (final code in allLanguages.keys) {
      if (sender.contains('_$code') || sender.contains(':$code')) {
        return allLanguages[code]!;
      }
    }
    
    // Return the id as fallback
    return 'Language $id';
  }

  /// Get the numeric ID for a language code in a session
  static String? getNumericIdForCode(String code, Map<String, String> languageMap) {
    for (final entry in languageMap.entries) {
      if (entry.value == code || entry.value == getDisplayName(code)) {
        return entry.key;
      }
    }
    return null;
  }
}
