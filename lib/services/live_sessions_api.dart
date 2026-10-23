// live_sessions_api.dart
//
// Client for finished live sessions stored on the Flask backend
// (`/api/live/saved…`, see lib/live_relay.py). Sessions belong to the
// email inside the KIT token, so every call sends it as a bearer token.

import 'dart:convert';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:http/http.dart' as http;

class LiveSessionsException implements Exception {
  LiveSessionsException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  bool get isAuth => statusCode == 401;
  @override
  String toString() => message;
}

/// One transcript column: the original ('asr') or a translation.
class SavedLane {
  SavedLane({required this.key, required this.title, required this.text});
  final String key;
  final String title;
  final String text;

  factory SavedLane.fromJson(Map<String, dynamic> j) => SavedLane(
        key: j['key']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        text: j['text']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {'key': key, 'title': title, 'text': text};
}

/// List entry (no full text).
class LiveSessionSummary {
  LiveSessionSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.duration,
    required this.server,
    required this.inputLanguages,
    required this.outputLanguages,
    required this.wordCount,
    required this.preview,
  });

  final String id;
  final String name;
  final DateTime? createdAt;
  final Duration duration;
  final String server;
  final List<String> inputLanguages;
  final List<String> outputLanguages;
  final int wordCount;
  final String preview;

  factory LiveSessionSummary.fromJson(Map<String, dynamic> j) =>
      LiveSessionSummary(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '')
            ?.toLocal(),
        duration: _seconds(j['duration_s']),
        server: j['server']?.toString() ?? '',
        inputLanguages: _strings(j['input_languages']),
        outputLanguages: _strings(j['output_languages']),
        wordCount: (j['word_count'] as num?)?.toInt() ?? 0,
        preview: j['preview']?.toString() ?? '',
      );
}

/// Full saved session.
class LiveSessionRecord {
  LiveSessionRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.duration,
    required this.server,
    required this.inputLanguages,
    required this.outputLanguages,
    required this.settings,
    required this.lanes,
  });

  final String id;
  final String name;
  final DateTime? createdAt;
  final Duration duration;
  final String server;
  final List<String> inputLanguages;
  final List<String> outputLanguages;
  final Map<String, dynamic> settings;
  final List<SavedLane> lanes;

  factory LiveSessionRecord.fromJson(Map<String, dynamic> j) =>
      LiveSessionRecord(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '')
            ?.toLocal(),
        duration: _seconds(j['duration_s']),
        server: j['server']?.toString() ?? '',
        inputLanguages: _strings(j['input_languages']),
        outputLanguages: _strings(j['output_languages']),
        settings: (j['settings'] as Map?)?.cast<String, dynamic>() ?? {},
        lanes: ((j['lanes'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => SavedLane.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );
}

class LiveSessionsApi {
  static String get _base => '$flaskServerUrl/api/live/saved';

  static Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await InternalAuthService.getToken() ?? '';
    if (token.isEmpty) {
      throw LiveSessionsException('Not connected to the internal server.',
          statusCode: 401);
    }
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  static Future<List<LiveSessionSummary>> list() async {
    final r = await http.get(Uri.parse(_base), headers: await _headers());
    _check(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return ((body['sessions'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => LiveSessionSummary.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  static Future<LiveSessionRecord> get(String id) async {
    final r =
        await http.get(Uri.parse('$_base/$id'), headers: await _headers());
    _check(r);
    return LiveSessionRecord.fromJson(
        jsonDecode(r.body) as Map<String, dynamic>);
  }

  static Future<void> delete(String id) async {
    final r =
        await http.delete(Uri.parse('$_base/$id'), headers: await _headers());
    _check(r);
  }

  /// Saves a finished session. Returns its id.
  static Future<String> save({
    String? id,
    required String name,
    required DateTime createdAt,
    required Duration duration,
    required String server,
    required List<String> inputLanguages,
    required List<String> outputLanguages,
    required Map<String, dynamic> settings,
    required List<SavedLane> lanes,
  }) async {
    final r = await http.post(
      Uri.parse(_base),
      headers: await _headers(json: true),
      body: jsonEncode({
        if (id != null) 'id': id,
        'name': name,
        'created_at': createdAt.toUtc().toIso8601String(),
        'duration_s': duration.inMilliseconds / 1000.0,
        'server': server,
        'input_languages': inputLanguages,
        'output_languages': outputLanguages,
        'settings': settings,
        'lanes': lanes.map((l) => l.toJson()).toList(),
      }),
    );
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  static void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    String msg = 'HTTP ${r.statusCode}';
    try {
      final b = jsonDecode(r.body);
      if (b is Map && b['error'] != null) msg = b['error'].toString();
    } catch (_) {}
    throw LiveSessionsException(msg, statusCode: r.statusCode);
  }
}

Duration _seconds(Object? v) =>
    Duration(milliseconds: (((v as num?) ?? 0) * 1000).round());

List<String> _strings(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList() : <String>[];

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatDateTime(DateTime? t) {
  if (t == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
