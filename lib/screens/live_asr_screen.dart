// live_asr_screen.dart
//
// One-shot live speech recognition + translation from the browser's
// own microphone.
//
// Layout (top → bottom), mirroring session_detail_screen.dart:
//   1. Microphone control bar (start / stop, timer, level meter)
//   2. Internal server picker + Connect / Token section
//   3. Live Session Settings — the same options as the offline
//      "Job Settings" panel
//   4. Transcript + translation panels
//
// Opened from LiveSessionsScreen. No video job is created and nothing
// goes into the video job history, presets or SharedPreferences. When
// a session finishes (or the user leaves mid-recording), the final
// transcript + translations are saved once to the backend
// (/api/live/saved) and appear in the Live Sessions list.
//
// Flow:
//   1. POST {flask}/api/live/start               → live_id
//   2. EventSource {flask}/api/live/<id>/events   (ASR + MT messages)
//   3. mic chunks → POST {flask}/api/live/<id>/audio (pcm_s16le 16 kHz)
//   4. POST {flask}/api/live/<id>/stop, wait for the last results.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/services/browser_microphone.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/services/live_sessions_api.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web/web.dart' as web;

enum _LiveState { idle, starting, recording, finishing, finished }

enum _SaveStatus { none, saving, saved, failed }

/// One output panel: the original transcript or one translation.
class _Lane {
  _Lane(this.key, this.title);
  final String key; // 'asr' or a language code
  final String title;
  final List<String> finals = <String>[];
  String pending = ''; // current unstable hypothesis
  final ScrollController scroll = ScrollController();

  String get fullText => finals.join('\n');
  bool get isEmpty => finals.isEmpty && pending.isEmpty;
}

class LiveAsrScreen extends StatefulWidget {
  const LiveAsrScreen({super.key});

  @override
  State<LiveAsrScreen> createState() => _LiveAsrScreenState();
}

class _LiveAsrScreenState extends State<LiveAsrScreen> {
  // ─────────────────────────────────────────────────────────────────
  //  RESPONSIVE HELPERS (same breakpoints as session_detail_screen)
  // ─────────────────────────────────────────────────────────────────
  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;
  bool _isWide(BuildContext c) => MediaQuery.sizeOf(c).width >= 1000;
  double _pagePadding(BuildContext c) =>
      _isNarrow(c) ? 12 : (_isWide(c) ? 24 : 16);
  double _sectionGap(BuildContext c) =>
      _isNarrow(c) ? 12 : (_isWide(c) ? 24 : 16);
  double _bodySize(BuildContext c) => _isNarrow(c) ? 13 : 14;

  // ─── Connection state ─────────────────────────────────────────────
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _showTokenInput = false;
  bool _showBookmarklet = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

  // Bookmarklet: one click on the /gettoken page copies the token.
  static const String _bookmarkletJs =
      "javascript:(function(){"
      "const pre=document.querySelector('pre');"
      "if(!pre){alert('Not on the /gettoken page');return;}"
      "const t=pre.textContent.trim();"
      "navigator.clipboard.writeText(t).then("
      "()=>alert('Token copied — go back to the app and click \"Paste Token\"'),"
      "()=>prompt('Copy manually:',t)"
      ");"
      "})();";

  // ─── Session settings (same fields as the offline Job Settings) ───
  // In memory only — nothing here is persisted.
  final _formKey = GlobalKey<FormState>();
  final ExpansibleController _settingsTileController = ExpansibleController();
  late final TextEditingController _sessionNameController;
  final TextEditingController _topicNameController =
      TextEditingController(text: publicServerUrl);
  final TextEditingController _speakerNameController = TextEditingController();
  final TextEditingController _shortenController = TextEditingController();
  final TextEditingController _muteController =
      TextEditingController(text: '120');
  final TextEditingController _pauseController =
      TextEditingController(text: '2');
  String _date = '';

  final List<String> _inputLanguages = <String>['en', 'de'];
  final List<String> _outputLanguages = <String>['en', 'de'];
  final List<String> _audioLanguages = <String>[];

  String _availability = 'private';
  bool _profanityFilter = true;
  bool _filterMusic = true;
  bool _enableSummarization = true;
  bool _enableLiveNotes = false;
  bool _enableDiarization = false;
  bool _enableAIAssistant = false;
  // Off by default: the transcript is saved by this app (Live Sessions
  // list); this flag only asks KIT to archive the session on its side.
  bool _saveSession = false;
  bool _distinguishUnknownSpeakers = false;
  String _smartChaptering = 'online_dynamic';
  String _format = 'online';
  String _ttsQualityMode = 'low_latency';
  String _errorCorrection = 'None';
  final List<String> _postproduction = <String>[];

  bool _languagesLoaded = LanguageConfig.isLoaded;

  static const List<String> _availabilityOptions = [
    'private',
    'private+qr',
    'kitemployee',
    'kitall',
    'public'
  ];
  static const List<String> _formatOptions = [
    'mixed',
    'resending',
    'online',
    'offline'
  ];
  static const List<String> _chapteringOptions = [
    'online_dynamic',
    'online_static',
    'offline',
    'streaming_simple'
  ];
  static const List<String> _ttsQualityOptions = [
    'low_latency',
    'high_quality'
  ];
  static const List<String> _errorCorrectionOptions = [
    'None',
    'dialog',
    'dialog2'
  ];
  static const List<String> _postproductionOptions = ['50', '70', '90'];

  // ─── Live session ─────────────────────────────────────────────────
  _LiveState _state = _LiveState.idle;
  String? _liveId;
  String _token = '';
  String? _error;
  BrowserMicrophone? _mic;
  StreamSubscription<Uint8List>? _chunkSub;
  StreamSubscription<double>? _levelSub;
  web.EventSource? _events;
  Timer? _finishTimer;

  // Saving the finished session to the Live Sessions list.
  _SaveStatus _saveStatus = _SaveStatus.none;
  String? _saveError;
  String? _savedId; // = live_id, so a retry overwrites instead of duplicating
  DateTime? _startedAt;

  double _level = 0;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _clock;

  // Audio upload queue (sequential, so chunks arrive in order).
  final List<Uint8List> _outbox = <Uint8List>[];
  bool _sending = false;

  // Output panels; key order = display order.
  final Map<String, _Lane> _lanes = <String, _Lane>{};
  String _selectedLane = 'asr';

  bool get _isActive =>
      _state == _LiveState.starting ||
      _state == _LiveState.recording ||
      _state == _LiveState.finishing;

  // ═══════════════════════════════════════════════════════════════════
  //  INIT / DISPOSE
  // ═══════════════════════════════════════════════════════════════════
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = '${now.year}-${_two(now.month)}-${_two(now.day)}';
    _sessionNameController = TextEditingController(text: _defaultSessionName());
    _init();
  }

  Future<void> _init() async {
    await ServerConfigService.load();
    if (!LanguageConfig.isLoaded) {
      try {
        await LanguageConfig.load();
      } catch (e) {
        debugPrint('LanguageConfig.load failed: $e');
      }
    }
    final inputs = LanguageConfig.getSortedInputLanguages();
    final outputs = LanguageConfig.getSortedOutputLanguages();
    final audio = LanguageConfig.getSortedAudioLanguages();
    _inputLanguages.removeWhere((c) => !inputs.contains(c));
    _outputLanguages.removeWhere((c) => !outputs.contains(c));
    _audioLanguages.removeWhere((c) => !audio.contains(c));
    if (_inputLanguages.isEmpty && inputs.isNotEmpty) {
      _inputLanguages.add(inputs.first);
    }
    await _checkConnection();
    if (mounted) setState(() => _languagesLoaded = true);
  }

  @override
  void dispose() {
    // Leaving the screen ends the session. Nothing is kept.
    _teardown(notifyServer: true);
    for (final l in _lanes.values) {
      l.scroll.dispose();
    }
    _tokenController.dispose();
    _sessionNameController.dispose();
    _topicNameController.dispose();
    _speakerNameController.dispose();
    _shortenController.dispose();
    _muteController.dispose();
    _pauseController.dispose();
    super.dispose();
  }

  String _defaultSessionName() {
    final n = DateTime.now();
    return 'live_${n.year}${_two(n.month)}${_two(n.day)}-'
        '${_two(n.hour)}${_two(n.minute)}${_two(n.second)}';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SERVER + CONNECTION (same behaviour as session_detail_screen)
  // ═══════════════════════════════════════════════════════════════════
  Future<void> _checkConnection() async {
    final token = await InternalAuthService.getToken();
    if (mounted) {
      setState(() => _isConnected = token != null && token.isNotEmpty);
    }
  }

  Future<void> _changeServer(String url) async {
    if (url == internalServerUrl || _isActive) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch internal server?'),
        content: Text(
          'Switch to:\n$url\n\n'
          'Tokens you created on the previous server may no longer work. '
          'You will likely need to reconnect and paste a new token.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ServerConfigService.setServer(url);
    await ServerConfigService.load();
    if (!mounted) return;

    // Tokens are per-server; drop the old one.
    await InternalAuthService.clearManualToken();
    setState(() {
      _isConnected = false;
      _tokenStatus = '🔀 Switched to: $url — paste a token for this host';
    });
    await _checkConnection();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Server switched to $url')),
      );
    }
  }

  Future<void> _connectToInternal() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      final success = await InternalAuthService.loginWithOAuth();
      await _checkConnection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '✅ Connected to internal server!'
              : '❌ Connection failed. Please try again.'),
          backgroundColor: success ? null : Colors.red,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _setManualToken() async {
    final raw = _tokenController.text;
    final token = _extractToken(raw) ?? raw.trim();
    if (token.isEmpty) {
      setState(() => _tokenStatus = '⚠️ Please enter a token');
      return;
    }
    try {
      await InternalAuthService.setManualToken(token);
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _tokenStatus = '✅ Token set successfully!';
        _showTokenInput = false;
        _tokenController.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _tokenStatus = '❌ Error: $e');
    }
  }

  Future<void> _clearManualToken() async {
    try {
      await InternalAuthService.clearManualToken();
      if (!mounted) return;
      setState(() {
        _isConnected = false;
        _tokenStatus = 'Token cleared';
        _tokenController.clear();
        _showTokenInput = false;
      });
      await _checkConnection();
    } catch (e) {
      if (mounted) setState(() => _tokenStatus = '❌ Error: $e');
    }
  }

  void _openTokenPage() {
    web.window.open('$internalServerUrl/gettoken', 'gettoken_tab');
    setState(() => _tokenStatus =
        '📋 Copy the token from the new tab, then click "Paste Token"');
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final text =
          (await web.window.navigator.clipboard.readText().toDart).toDart;
      if (text.isEmpty) {
        setState(() => _tokenStatus = '⚠️ Clipboard is empty');
        return;
      }
      final token = _extractToken(text);
      if (token == null || token.isEmpty) {
        setState(() => _tokenStatus = '⚠️ No token found in clipboard');
        return;
      }
      _tokenController.text = token;
      setState(() => _tokenStatus = '✅ Token extracted — saving...');
      await _setManualToken();
    } catch (e) {
      if (mounted) {
        setState(() => _tokenStatus = '⚠️ Clipboard read failed: $e');
      }
    }
  }

  void _copyBookmarklet() {
    Clipboard.setData(const ClipboardData(text: _bookmarkletJs));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Bookmarklet copied. Create a new bookmark and paste this as its URL.',
        ),
      ),
    );
  }

  String? _extractToken(String raw) {
    if (raw.trim().isEmpty) return null;
    final pre = RegExp(r'<pre>\s*([^<]+?)\s*</pre>', multiLine: true)
        .firstMatch(raw);
    if (pre != null) {
      final t = pre.group(1)?.trim();
      if (t != null && t.isNotEmpty) return t;
    }
    final cookie = RegExp(r"([^\s'<>|]+\|\d{10}\|[^\s'<>]+)").firstMatch(raw);
    if (cookie != null) return cookie.group(1)?.trim();
    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LIVE SESSION
  // ═══════════════════════════════════════════════════════════════════

  /// The same fields the offline `/upload` sends, minus the video and
  /// the token. The relay forwards them to KIT unchanged.
  Map<String, dynamic> _settingsPayload() => <String, dynamic>{
        'name': _sessionNameController.text.trim(),
        'topicname': _topicNameController.text.trim(),
        'date': _date,
        'speakername': _speakerNameController.text.trim(),
        'availability': _availability,
        'format': _format,
        'smartChaptering': _smartChaptering,
        'errorCorrection': _errorCorrection,
        'ttsQualityMode': _ttsQualityMode,
        'audioLanguage': _audioLanguages,
        'profanity': _profanityFilter ? '1' : '0',
        'filter_music': _filterMusic ? '1' : '0',
        'summarization': _enableSummarization ? '1' : '0',
        'notes': _enableLiveNotes ? '1' : '0',
        'saasr': _enableDiarization ? '1' : '0',
        'aiassistant': _enableAIAssistant ? '1' : '0',
        'logging': _saveSession ? '1' : '0',
        'distinguish_unknown_speakers':
            _distinguishUnknownSpeakers ? '1' : '0',
        'postproduction': _postproduction,
        'shorten': _shortenController.text.trim(),
        'mute': (int.tryParse(_muteController.text.trim()) ?? 120).toString(),
        'pause':
            (double.tryParse(_pauseController.text.trim()) ?? 2.0).toString(),
        'legals': '1',
      };

  Future<void> _start() async {
    if (_isActive) return;
    if (!(_formKey.currentState?.validate() ?? true)) {
      _settingsTileController.expand();
      return;
    }
    if (_inputLanguages.isEmpty) {
      setState(() => _error = 'Please pick at least one input language.');
      _settingsTileController.expand();
      return;
    }
    final token = await InternalAuthService.getToken() ?? '';
    if (token.isEmpty) {
      setState(() => _error = 'Connect to the internal server first.');
      return;
    }
    _token = token;

    _settingsTileController.collapse();
    setState(() {
      _state = _LiveState.starting;
      _error = null;
      _resetLanes();
    });

    // 1. Microphone first: no point opening a KIT session without it.
    final mic = BrowserMicrophone();
    try {
      await mic.start();
    } catch (e) {
      await mic.dispose();
      _fail(e.toString());
      return;
    }
    _mic = mic;

    // 2. Open the live session on KIT (via the Flask relay).
    try {
      final resp = await http.post(
        Uri.parse('$flaskServerUrl/api/live/start'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'token': token,
          'targetServer': internalServerUrl,
          'language': _inputLanguages,
          'mtLanguage': _outputLanguages,
          'settings': _settingsPayload(),
        }),
      );
      final body = _tryJson(resp.body);
      if (resp.statusCode != 200 || body?['live_id'] == null) {
        if (resp.statusCode == 401) await _checkConnection();
        throw Exception(body?['error'] ?? 'HTTP ${resp.statusCode}');
      }
      _liveId = body!['live_id'] as String;
      _savedId = _liveId;
      _startedAt = DateTime.now();
      _saveStatus = _SaveStatus.none;
      _saveError = null;
    } catch (e) {
      _fail('Could not start the live session: $e');
      return;
    }
    if (!mounted) return;

    // 3. Results stream.
    _openEvents();

    // 4. Pump mic audio to the relay.
    _chunkSub = mic.chunks.listen(_enqueue);
    _levelSub = mic.levels.listen((v) {
      if (mounted) setState(() => _level = v);
    });

    _stopwatch
      ..reset()
      ..start();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WakelockPlus.enable().catchError((_) {});

    setState(() => _state = _LiveState.recording);
  }

  Future<void> _stop() async {
    if (_state != _LiveState.recording) return;
    setState(() => _state = _LiveState.finishing);

    _stopwatch.stop();
    _clock?.cancel();
    await _mic?.stop(); // flushes the last partial chunk into _outbox

    // Let queued audio reach the server (max ~5 s).
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((_outbox.isNotEmpty || _sending) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await _postStop();

    // Keep listening briefly for the final ASR / MT results; the relay
    // sends an `end` event when KIT is done.
    _finishTimer = Timer(const Duration(seconds: 15), _finish);
  }

  void _finish() {
    if (!mounted) return;
    _teardown(notifyServer: false);
    setState(() {
      for (final l in _lanes.values) {
        if (l.pending.isNotEmpty) {
          l.finals.add(l.pending);
          l.pending = '';
        }
      }
      _state = _LiveState.finished;
    });
    _saveToHistory();
  }

  void _fail(String message) {
    _teardown(notifyServer: true);
    final hasText = _lanes.values.any((l) => !l.isEmpty);
    if (mounted) {
      setState(() {
        _error = message;
        _state = hasText ? _LiveState.finished : _LiveState.idle;
      });
    }
    if (hasText) _saveToHistory();
  }

  /// Saves the transcript + translations to the Live Sessions list.
  /// Idempotent: the record id is the live_id, so retries overwrite.
  Future<void> _saveToHistory() async {
    final lanes = <SavedLane>[
      for (final l in _lanes.values)
        if ('${l.fullText}\n${l.pending}'.trim().isNotEmpty)
          SavedLane(
            key: l.key,
            title: l.title,
            text: [...l.finals, if (l.pending.isNotEmpty) l.pending]
                .join('\n'),
          ),
    ];
    if (lanes.isEmpty) return;

    if (mounted) setState(() => _saveStatus = _SaveStatus.saving);
    try {
      _savedId = await LiveSessionsApi.save(
        id: _savedId,
        name: _sessionNameController.text.trim().isEmpty
            ? _defaultSessionName()
            : _sessionNameController.text.trim(),
        createdAt: _startedAt ?? DateTime.now(),
        duration: _stopwatch.elapsed,
        server: internalServerUrl,
        inputLanguages: List.of(_inputLanguages),
        outputLanguages: List.of(_outputLanguages),
        settings: _settingsPayload(),
        lanes: lanes,
      );
      if (mounted) setState(() => _saveStatus = _SaveStatus.saved);
    } catch (e) {
      debugPrint('saving live session failed: $e');
      if (mounted) {
        setState(() {
          _saveStatus = _SaveStatus.failed;
          _saveError = e.toString();
        });
      }
    }
  }

  Future<void> _postStop() async {
    final id = _liveId;
    if (id == null) return;
    try {
      await http.post(
        Uri.parse('$flaskServerUrl/api/live/$id/stop'),
        headers: {'Authorization': 'Bearer $_token'},
      );
    } catch (e) {
      debugPrint('live stop failed: $e');
    }
  }

  /// Releases mic, event stream, timers and wakelock. Safe to call twice.
  void _teardown({required bool notifyServer}) {
    _finishTimer?.cancel();
    _finishTimer = null;
    _clock?.cancel();
    _stopwatch.stop();
    _chunkSub?.cancel();
    _chunkSub = null;
    _levelSub?.cancel();
    _levelSub = null;
    final mic = _mic;
    _mic = null;
    mic?.dispose();
    _events?.close();
    _events = null;
    _outbox.clear();
    if (notifyServer &&
        _liveId != null &&
        (_state == _LiveState.recording || _state == _LiveState.starting)) {
      _postStop();
    }
    _liveId = null;
    _level = 0;
    WakelockPlus.disable().catchError((_) {});
  }

  void _newSession() {
    final old = _lanes.values.map((l) => l.scroll).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final s in old) {
        s.dispose();
      }
    });
    setState(() {
      _lanes.clear();
      _error = null;
      _state = _LiveState.idle;
      _stopwatch.reset();
      _saveStatus = _SaveStatus.none;
      _saveError = null;
      _savedId = null;
      _startedAt = null;
      _sessionNameController.text = _defaultSessionName();
    });
  }

  // ─── audio upload ────────────────────────────────────────────────
  void _enqueue(Uint8List chunk) {
    _outbox.add(chunk);
    _pump();
  }

  Future<void> _pump() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_outbox.isNotEmpty && _liveId != null) {
        final chunk = _outbox.removeAt(0);
        final resp = await http.post(
          Uri.parse('$flaskServerUrl/api/live/$_liveId/audio'),
          headers: {
            'Content-Type': 'application/octet-stream',
            'Authorization': 'Bearer $_token',
          },
          body: chunk,
        );
        if (resp.statusCode == 404) {
          _fail('The live session was closed by the server.');
          return;
        }
        if (resp.statusCode >= 400) {
          debugPrint('live audio: HTTP ${resp.statusCode} ${resp.body}');
        }
      }
    } catch (e) {
      debugPrint('live audio upload failed: $e');
    } finally {
      _sending = false;
    }
  }

  // ─── results ─────────────────────────────────────────────────────
  void _openEvents() {
    final es = web.EventSource('$flaskServerUrl/api/live/$_liveId/events');
    _events = es;

    es.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data == null || !data.isA<JSString>()) return;
      final msg = _tryJson((data as JSString).toDart);
      if (msg != null) _onKitMessage(msg);
    }).toJS;

    es.addEventListener(
      'end',
      ((web.Event _) {
        if (_state == _LiveState.finishing) {
          _finish();
        } else {
          es.close(); // KIT closed the stream while still recording
        }
      }).toJS,
    );

    es.addEventListener(
      'relay-error',
      ((web.MessageEvent e) {
        final d = e.data;
        final text = (d != null && d.isA<JSString>())
            ? (d as JSString).toDart
            : 'unknown error';
        if (mounted) setState(() => _error = 'Result stream: $text');
      }).toJS,
    );
  }

  void _onKitMessage(Map<String, dynamic> msg) {
    final control = msg['controll'] ?? msg['control'];
    if (control == 'END' && _state == _LiveState.finishing) {
      _finish();
      return;
    }

    final sender = (msg['sender'] ?? '').toString();
    final text = (msg['seq'] ?? msg['text'] ?? msg['translation'] ?? '')
        .toString()
        .trim();
    if (sender.isEmpty || text.isEmpty) return;

    final laneKey = _laneKeyForSender(sender, msg);
    final lane = laneKey == null ? null : _lanes[laneKey];
    if (lane == null) return;

    final unstable = msg['unstable'] == true;
    setState(() {
      if (unstable) {
        lane.pending = text;
      } else {
        lane.finals.add(text);
        lane.pending = '';
      }
    });
    _scrollToEnd(lane);
  }

  /// Maps a KIT sender ("asr:…", "mt:…_de", …) to one of our panels.
  /// Returns null for senders we don't display (tts, lip-sync, …).
  String? _laneKeyForSender(String sender, Map<String, dynamic> msg) {
    if (sender.startsWith(RegExp(r'(tts|lip|textstructurer|saasr)'))) {
      return null;
    }
    if (sender.startsWith('asr')) return 'asr';
    if (!sender.startsWith('mt')) return null;

    for (final k in const ['language', 'lang', 'target_language']) {
      final v = msg[k]?.toString().toLowerCase();
      if (v != null && _lanes.containsKey(v)) return v;
    }
    for (final code in _lanes.keys) {
      if (code == 'asr') continue;
      if (RegExp('[:_\\-]${RegExp.escape(code)}(?![a-z])',
              caseSensitive: false)
          .hasMatch(sender)) {
        return code;
      }
    }
    final mtLanes = _lanes.keys.where((k) => k != 'asr').toList();
    return mtLanes.length == 1 ? mtLanes.first : null;
  }

  void _resetLanes() {
    // The old ListViews still hold these until the next frame.
    final old = _lanes.values.map((l) => l.scroll).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final s in old) {
        s.dispose();
      }
    });
    final inputs = _inputLanguages.map(LanguageConfig.getDisplayName).join(', ');
    _lanes
      ..clear()
      ..['asr'] = _Lane('asr', 'Original · $inputs');
    for (final code in _outputLanguages) {
      // A single spoken language needs no "translation" into itself.
      if (_inputLanguages.length == 1 && code == _inputLanguages.first) {
        continue;
      }
      _lanes[code] = _Lane(code, LanguageConfig.getDisplayName(code));
    }
    if (!_lanes.containsKey(_selectedLane)) _selectedLane = 'asr';
  }

  void _scrollToEnd(_Lane lane) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (lane.scroll.hasClients) {
        lane.scroll.jumpTo(lane.scroll.position.maxScrollExtent);
      }
    });
  }

  // ─── copy / download (the only way to keep the result) ───────────
  void _copyLane(_Lane lane) {
    Clipboard.setData(ClipboardData(text: lane.fullText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: ${lane.title}')),
    );
  }

  void _downloadLane(_Lane lane) {
    final name = _sessionNameController.text.trim().isEmpty
        ? _defaultSessionName()
        : _sessionNameController.text.trim();
    final blob = web.Blob(
      <JSAny>[lane.fullText.toJS].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    (web.HTMLAnchorElement()
          ..href = url
          ..download = '${name}_${lane.key}.txt')
        .click();
    web.URL.revokeObjectURL(url);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static Map<String, dynamic>? _tryJson(String s) {
    try {
      final d = jsonDecode(s);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _confirmLeave() async {
    final unsaved = _saveStatus == _SaveStatus.failed;
    if (!_isActive && !unsaved) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave live session?'),
        content: Text(_isActive
            ? 'Recording will stop. What has been transcribed so far is '
                'saved to Live Sessions.'
            : 'Saving to Live Sessions failed, so this transcript is not '
                'stored. Copy or download it first if you need it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final gap = _sectionGap(context);
    final screenH = MediaQuery.sizeOf(context).height;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await _confirmLeave()) return;
        if (_isActive) {
          // Stop now and keep what we have, before the screen goes away.
          _teardown(notifyServer: true);
          for (final l in _lanes.values) {
            if (l.pending.isNotEmpty) {
              l.finals.add(l.pending);
              l.pending = '';
            }
          }
          await _saveToHistory();
        }
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Live Session'),
          backgroundColor: Colors.blue.shade700,
          foregroundColor: Colors.white,
        ),
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top: _pagePadding(context),
              left: _pagePadding(context),
              right: _pagePadding(context),
              bottom: 80,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ─── 1. Microphone ───
                _buildControlBar(context),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  _buildErrorBanner(),
                ],
                SizedBox(height: gap),

                // ─── 2. Server + connection ───
                AbsorbPointer(
                  absorbing: _isActive,
                  child: Opacity(
                    opacity: _isActive ? 0.5 : 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildServerPicker(),
                        SizedBox(height: gap),
                        _buildConnectionSection(),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: gap),

                // ─── 3. Settings ───
                _buildSettingsCard(context),
                SizedBox(height: gap),

                // ─── 4. Transcript ───
                SizedBox(
                  height: math.max(360, screenH * 0.6),
                  child: _buildTranscriptArea(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── 1. Microphone control bar ───────────────────────────────────
  Widget _buildControlBar(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final recording = _state == _LiveState.recording;
    final busy =
        _state == _LiveState.starting || _state == _LiveState.finishing;

    final String status;
    switch (_state) {
      case _LiveState.idle:
        status = _isConnected
            ? 'Press the microphone to start'
            : 'Connect to the server below to start';
      case _LiveState.starting:
        status = 'Starting…';
      case _LiveState.recording:
        status = 'Listening';
      case _LiveState.finishing:
        status = 'Finishing — waiting for the last results…';
      case _LiveState.finished:
        status = switch (_saveStatus) {
          _SaveStatus.saving => 'Finished · saving…',
          _SaveStatus.saved => 'Finished · saved to Live Sessions',
          _SaveStatus.failed => 'Finished · NOT saved',
          _SaveStatus.none => 'Finished',
        };
    }

    final elapsed = _stopwatch.elapsed;
    final clock = '${_two(elapsed.inMinutes)}:${_two(elapsed.inSeconds % 60)}';
    final size = _isNarrow(c) ? 64.0 : 76.0;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Tooltip(
              message: recording ? 'Stop' : 'Start live session',
              child: SizedBox.square(
                dimension: size,
                child: FilledButton(
                  onPressed: busy || !_isConnected
                      ? null
                      : (recording ? _stop : _start),
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor: recording ? Colors.red : scheme.primary,
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                        )
                      : Icon(recording ? Icons.stop : Icons.mic,
                          size: size * 0.45),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (recording) ...[
                        const Icon(Icons.fiber_manual_record,
                            color: Colors.red, size: 14),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          status,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: _bodySize(c) + 1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_state != _LiveState.idle)
                        Text(
                          clock,
                          style: TextStyle(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            fontSize: _bodySize(c) + 1,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: recording ? _level : 0,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation(
                        _level > 0.8 ? Colors.orange : Colors.green,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_inputLanguages.map(LanguageConfig.getDisplayName).join(', ')}'
                    '${_outputLanguages.isEmpty ? '' : '  →  ${_outputLanguages.map(LanguageConfig.getDisplayName).join(', ')}'}',
                    style: TextStyle(
                      fontSize: _bodySize(c) - 1,
                      color: Colors.grey.shade700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_state == _LiveState.finished &&
                _saveStatus == _SaveStatus.failed) ...[
              const SizedBox(width: 12),
              Tooltip(
                message: _saveError ?? '',
                child: FilledButton.icon(
                  onPressed: _saveToHistory,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Retry save'),
                ),
              ),
            ],
            if (_state == _LiveState.finished) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _newSession,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(_isNarrow(c) ? 'New' : 'New session'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Material(
      color: Colors.red.shade50,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.error_outline, color: Colors.red),
        title: Text(_error!, style: const TextStyle(color: Colors.red)),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _error = null),
        ),
      ),
    );
  }

  // ─── 2a. Server picker (same as session_detail_screen) ──────────
  Widget _buildServerPicker() {
    final currentLabel = labelForServer(internalServerUrl);
    final allServers = ServerConfigService.allServers;
    final customSet = ServerConfigService.customServers.toSet();

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.dns_outlined, size: 20, color: Colors.blueGrey),
            const SizedBox(width: 10),
            Text(
              'Internal server',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: _isNarrow(context) ? 12 : 14,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    currentLabel,
                    style: TextStyle(fontSize: _isNarrow(context) ? 12 : 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    internalServerUrl,
                    style: TextStyle(
                      fontSize: _isNarrow(context) ? 9 : 10,
                      color: Colors.grey[600],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Add custom server',
              icon: const Icon(Icons.add_circle_outline, size: 20),
              onPressed: _showAddServerDialog,
            ),
            PopupMenuButton<String>(
              tooltip: 'Switch server',
              icon: const Icon(Icons.swap_horiz, size: 20),
              onSelected: (value) async {
                if (value == '__add__') {
                  await _showAddServerDialog();
                } else {
                  await _changeServer(value);
                }
              },
              itemBuilder: (context) {
                final items = <PopupMenuEntry<String>>[];
                for (final url in allServers) {
                  final isSelected = url == internalServerUrl;
                  final isCustom = customSet.contains(url);
                  items.add(
                    PopupMenuItem<String>(
                      value: url,
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: isSelected ? Colors.blue : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        labelForServer(url),
                                        style: TextStyle(
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isCustom) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.shade50,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                              color: Colors.teal.shade200),
                                        ),
                                        child: Text(
                                          'custom',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: Colors.teal.shade800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  url,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey[600],
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (isCustom)
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () async {
                                await ServerConfigService.removeCustomServer(
                                    url);
                                if (!mounted) return;
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                    ),
                  );
                }
                items.add(const PopupMenuDivider());
                items.add(
                  const PopupMenuItem<String>(
                    value: '__add__',
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 18, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('Add server…',
                            style: TextStyle(color: Colors.blue)),
                      ],
                    ),
                  ),
                );
                return items;
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddServerDialog() async {
    final controller = TextEditingController(text: 'https://lt2srv-');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.dns_outlined, color: Colors.blueGrey),
            SizedBox(width: 8),
            Text('Add internal server'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the base URL of an LT2SRV host. The same '
                  'pattern the backend accepts is enforced here.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://lt2srv-alice.isl.iar.kit.edu',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                  validator: (value) {
                    final raw = (value ?? '').trim();
                    if (raw.isEmpty) return 'Enter a URL';
                    if (!raw.startsWith('https://')) {
                      return 'Must start with https://';
                    }
                    if (!isAllowedInternalServer(raw)) {
                      return 'Not a recognised lt2srv host';
                    }
                    final normalised = raw.endsWith('/')
                        ? raw.substring(0, raw.length - 1)
                        : raw;
                    if (ServerConfigService.allServers.contains(normalised)) {
                      return 'Already in the list';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Add'),
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              var url = controller.text.trim();
              if (url.endsWith('/')) url = url.substring(0, url.length - 1);
              Navigator.pop(ctx, url);
            },
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    final outcome = await ServerConfigService.addCustomServer(result);
    if (!mounted) return;
    switch (outcome) {
      case AddResult.added:
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added $result'),
            action: SnackBarAction(
              label: 'Switch to it',
              onPressed: () => _changeServer(result),
            ),
          ),
        );
      case AddResult.duplicate:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That server is already in the list.')),
        );
      case AddResult.invalid:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That does not look like a valid lt2srv host.')),
        );
    }
  }

  // ─── 2b. Connect / Token (same as session_detail_screen) ────────
  Widget _buildConnectionSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _isConnected ? Icons.check_circle : Icons.info_outline,
                color: _isConnected ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isConnected
                      ? 'Connected'
                      : 'Not connected — required for live sessions',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: _isConnected ? Colors.green : Colors.grey.shade700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _showTokenInput = !_showTokenInput;
                  if (!_showTokenInput) {
                    _tokenStatus = '';
                    _tokenController.clear();
                    _showBookmarklet = false;
                  }
                }),
                icon: Icon(
                  _showTokenInput ? Icons.keyboard_arrow_up : Icons.vpn_key,
                  size: 18,
                ),
                label: Text(_showTokenInput ? 'Hide Token' : 'Manual Token'),
                style: TextButton.styleFrom(foregroundColor: Colors.blue),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _isConnecting ? null : _connectToInternal,
                tooltip: _isConnected ? 'Reconnect' : 'Connect',
                icon: _isConnecting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_isConnected ? Icons.link : Icons.link_off),
              ),
            ],
          ),
          if (_showTokenInput) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber[200]!),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: Colors.amber[800]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '1. Click "Get Token" → new tab opens.\n'
                      '2. On that tab press Ctrl+A then Ctrl+C.\n'
                      '3. Come back and click "Paste Token".',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.amber[900],
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                hintText: 'Token will appear here after pasting...',
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                errorText: _tokenStatus.contains('❌') ? _tokenStatus : null,
                helperText: _tokenStatus.contains('✅') ? _tokenStatus : null,
                helperStyle: const TextStyle(color: Colors.green),
                suffixIcon: _tokenController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () =>
                            setState(() => _tokenController.clear()),
                      )
                    : null,
              ),
              maxLines: 2,
              minLines: 1,
              onChanged: (_) {
                if (_tokenStatus.isNotEmpty && !_tokenStatus.startsWith('📋')) {
                  setState(() => _tokenStatus = '');
                }
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openTokenPage,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Get Token'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('Paste Token'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _setManualToken,
                    icon: const Icon(Icons.save, size: 18),
                    label: const Text('Set Manually'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _clearManualToken,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('Clear'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  ),
                ),
              ],
            ),
            if (_tokenStatus.isNotEmpty &&
                !_tokenStatus.contains('❌') &&
                !_tokenStatus.contains('✅'))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _tokenStatus,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _showBookmarklet = !_showBookmarklet),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _showBookmarklet
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18,
                      color: Colors.blueGrey,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Power-user tip: one-click copy bookmarklet',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blueGrey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showBookmarklet) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blueGrey[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blueGrey[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Create a bookmark whose URL is the text below. Then '
                      'on the /gettoken page, click it once to copy the token.',
                      style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blueGrey[100]!),
                      ),
                      child: const SelectableText(
                        _bookmarkletJs,
                        style:
                            TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _copyBookmarklet,
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy Bookmarklet'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blueGrey[800],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ─── 3. Settings (same options as the offline Job Settings) ─────
  Widget _buildSettingsCard(BuildContext c) {
    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Theme(
        data: Theme.of(c).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          controller: _settingsTileController,
          enabled: !_isActive,
          leading: const Icon(Icons.settings, color: Colors.blue),
          title: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              const Text(
                'Live Session Settings',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_inputLanguages.length} in · '
                  '${_outputLanguages.length} out · '
                  '${_audioLanguages.length} audio',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.blue.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (_isActive)
                Text(
                  'locked while live',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
            ],
          ),
          initiallyExpanded: false,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: _languagesLoaded
                  ? _buildSettingsPanel()
                  : const Center(child: CircularProgressIndicator()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _settingsTileController.collapse(),
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                  label: const Text('Collapse'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPanel() {
    final inputLangCodes = LanguageConfig.getSortedInputLanguages();
    final outputLangCodes = LanguageConfig.getSortedOutputLanguages();
    final audioLangCodes = LanguageConfig.getSortedAudioLanguages();

    void toggle(List<String> list, String code) => setState(() {
          list.contains(code) ? list.remove(code) : list.add(code);
        });
    void replace(List<String> list, List<String> codes) => setState(() {
          list
            ..clear()
            ..addAll(codes);
        });

    Widget numberField(TextEditingController ctl, String label, bool isInt) =>
        TextFormField(
          controller: ctl,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          validator: (val) {
            if (val == null || val.isEmpty) return null;
            final ok = isInt ? int.tryParse(val) : double.tryParse(val);
            return ok == null ? 'Enter a number' : null;
          },
        );

    Widget check(String title, bool value, ValueChanged<bool> set) =>
        CheckboxListTile(
          title: Text(title),
          value: value,
          onChanged: (v) => setState(() => set(v ?? false)),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        );

    final mute = numberField(_muteController, 'Notify timeout (minutes)', true);
    final pause =
        numberField(_pauseController, 'Speech segment timeout (seconds)', false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _sessionNameController,
          decoration: const InputDecoration(
            labelText: 'Session Name',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _topicNameController,
          readOnly: true,
          enabled: false,
          decoration: const InputDecoration(
            labelText: 'Topic Name',
            helperText: 'Locked — fixed application identifier.',
            helperStyle: TextStyle(fontSize: 11),
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.lock_outline, size: 18),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _date,
          decoration: const InputDecoration(
            labelText: 'Date (YYYY-MM-DD)',
            border: OutlineInputBorder(),
          ),
          onChanged: (val) => _date = val,
          validator: (val) {
            if (val == null || val.isEmpty) return 'Date is required';
            if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(val)) {
              return 'Use YYYY-MM-DD format';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _speakerNameController,
          decoration: const InputDecoration(
            labelText: 'Speaker Name',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _buildLanguageBlock(
          title: 'Input Languages',
          availableCodes: inputLangCodes,
          selected: _inputLanguages,
          nameFor: LanguageConfig.getInputLanguageName,
          onToggle: (c) => toggle(_inputLanguages, c),
          onReplaceAll: (l) => replace(_inputLanguages, l),
        ),
        const SizedBox(height: 16),
        _buildLanguageBlock(
          title: 'Output Languages (Translation)',
          availableCodes: outputLangCodes,
          selected: _outputLanguages,
          nameFor: LanguageConfig.getOutputLanguageName,
          onToggle: (c) => toggle(_outputLanguages, c),
          onReplaceAll: (l) => replace(_outputLanguages, l),
        ),
        const SizedBox(height: 16),
        _buildLanguageBlock(
          title: 'Generated Audio Languages',
          availableCodes: audioLangCodes,
          selected: _audioLanguages,
          nameFor: LanguageConfig.getAudioLanguageName,
          onToggle: (c) => toggle(_audioLanguages, c),
          onReplaceAll: (l) => replace(_audioLanguages, l),
        ),
        const SizedBox(height: 16),
        _buildDropdownField(
          label: 'Availability',
          value: _availability,
          options: _availabilityOptions,
          onChanged: (v) => setState(() => _availability = v!),
        ),
        const SizedBox(height: 16),
        _buildDropdownField(
          label: 'Presentation Format',
          value: _format,
          options: _formatOptions,
          onChanged: (v) => setState(() => _format = v!),
        ),
        const SizedBox(height: 16),
        _buildDropdownField(
          label: 'Smart Chaptering',
          value: _smartChaptering,
          options: _chapteringOptions,
          onChanged: (v) => setState(() => _smartChaptering = v!),
        ),
        const SizedBox(height: 16),
        _buildDropdownField(
          label: 'TTS Quality Mode',
          value: _ttsQualityMode,
          options: _ttsQualityOptions,
          onChanged: (v) => setState(() => _ttsQualityMode = v!),
        ),
        const SizedBox(height: 16),
        _buildDropdownField(
          label: 'Error Correction',
          value: _errorCorrection,
          options: _errorCorrectionOptions,
          onChanged: (v) => setState(() => _errorCorrection = v!),
        ),
        const SizedBox(height: 16),
        const Text('Shortening (Post-production)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _postproductionOptions
              .map((opt) => FilterChip(
                    label: Text(opt),
                    selected: _postproduction.contains(opt),
                    onSelected: (_) => toggle(_postproduction, opt),
                  ))
              .toList(),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _shortenController,
          decoration: const InputDecoration(
            labelText: 'Permanent Name (alphanumeric only)',
            border: OutlineInputBorder(),
            hintText: 'Leave empty for random',
          ),
          validator: (val) {
            if (val != null &&
                val.isNotEmpty &&
                !RegExp(r'^[A-Za-z0-9]*$').hasMatch(val)) {
              return 'Only letters and numbers allowed';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        if (_isNarrow(context))
          Column(children: [mute, const SizedBox(height: 12), pause])
        else
          Row(children: [
            Expanded(child: mute),
            const SizedBox(width: 16),
            Expanded(child: pause),
          ]),
        const SizedBox(height: 16),
        const Text('Features',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Wrap(
          spacing: 16,
          children: [
            check('Filter Profanity', _profanityFilter,
                (v) => _profanityFilter = v),
            check('Filter Music', _filterMusic, (v) => _filterMusic = v),
            check('Enable Summarization', _enableSummarization,
                (v) => _enableSummarization = v),
            check('Enable Live Notes', _enableLiveNotes,
                (v) => _enableLiveNotes = v),
            check('Enable Speaker Diarization', _enableDiarization,
                (v) => _enableDiarization = v),
            check('Enable AI Assistant', _enableAIAssistant,
                (v) => _enableAIAssistant = v),
            check('Save Session on KIT server (logging)', _saveSession,
                (v) => _saveSession = v),
            check('Distinguish unknown speakers', _distinguishUnknownSpeakers,
                (v) => _distinguishUnknownSpeakers = v),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Finished sessions are saved to the Live Sessions list by this '
            'app. "Save Session" additionally asks the KIT server to archive '
            'it on its side.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  /// Same chip block as session_detail_screen's _buildLanguageBlock.
  Widget _buildLanguageBlock({
    required String title,
    required List<String> availableCodes,
    required List<String> selected,
    required String Function(String code) nameFor,
    required void Function(String code) onToggle,
    required void Function(List<String>) onReplaceAll,
  }) {
    final narrow = _isNarrow(context);
    Widget action(String label, VoidCallback? onPressed) => TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 6 : 8),
            minimumSize: Size(0, narrow ? 28 : 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: TextStyle(fontSize: narrow ? 12 : 13),
          ),
          child: Text(label),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: _bodySize(context),
                ),
              ),
            ),
            action(
              'All',
              selected.length == availableCodes.length
                  ? null
                  : () => onReplaceAll([...availableCodes]),
            ),
            const SizedBox(width: 2),
            action('None',
                selected.isEmpty ? null : () => onReplaceAll(const [])),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: narrow ? 6 : 8,
          runSpacing: 4,
          children: availableCodes
              .map((code) => FilterChip(
                    label: Text(
                      '${nameFor(code)} ($code)',
                      style: TextStyle(fontSize: narrow ? 11 : 13),
                    ),
                    selected: selected.contains(code),
                    onSelected: (_) => onToggle(code),
                    visualDensity:
                        narrow ? VisualDensity.compact : VisualDensity.standard,
                  ))
              .toList(),
        ),
      ],
    );
  }

  /// Same as session_detail_screen's _buildDropdownField.
  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox(),
        items: options
            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  // ─── 4. Transcript panels ────────────────────────────────────────
  Widget _buildTranscriptArea(BuildContext c) {
    if (_lanes.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_none, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                'Transcript and translations appear here while you speak.\n'
                'Finished sessions are saved to the Live Sessions list.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    final lanes = _lanes.values.toList();

    if (_isWide(c) && lanes.length <= 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lanes.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: _buildLanePanel(c, lanes[i])),
          ],
        ],
      );
    }

    final selected = _lanes[_selectedLane] ?? lanes.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final l in lanes)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(l.title),
                    selected: l.key == selected.key,
                    onSelected: (_) => setState(() => _selectedLane = l.key),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _buildLanePanel(c, selected)),
      ],
    );
  }

  Widget _buildLanePanel(BuildContext c, _Lane lane) {
    final hasText = lane.finals.isNotEmpty;
    final textSize = _isNarrow(c) ? 15.0 : 17.0;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Theme.of(c).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(lane.key == 'asr' ? Icons.hearing : Icons.translate,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lane.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: hasText ? () => _copyLane(lane) : null,
                ),
                IconButton(
                  tooltip: 'Download .txt',
                  icon: const Icon(Icons.download, size: 18),
                  onPressed: hasText ? () => _downloadLane(lane) : null,
                ),
              ],
            ),
          ),
          Expanded(
            child: lane.isEmpty
                ? Center(
                    child: Text(
                      _state == _LiveState.recording ? '…' : '',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : SelectionArea(
                    child: ListView(
                      controller: lane.scroll,
                      padding: const EdgeInsets.all(12),
                      children: [
                        for (final t in lane.finals)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              t,
                              style: TextStyle(fontSize: textSize, height: 1.4),
                            ),
                          ),
                        if (lane.pending.isNotEmpty)
                          Text(
                            lane.pending,
                            style: TextStyle(
                              fontSize: textSize,
                              height: 1.4,
                              color: Colors.grey.shade600,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
