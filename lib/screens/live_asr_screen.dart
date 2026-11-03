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
import 'package:asr_live_translator/screens/session_output_screen.dart';
import 'package:asr_live_translator/services/live_sessions_api.dart';
import 'package:asr_live_translator/services/live_tts_player.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:asr_live_translator/services/ui_mode.dart';
import 'package:asr_live_translator/widgets/server_connection_panel.dart';
import 'package:asr_live_translator/widgets/language_picker.dart';
import 'package:asr_live_translator/widgets/session_share_card.dart';
import 'package:asr_live_translator/services/app_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web/web.dart' as web;

enum _LiveState { idle, starting, recording, finishing, finished }

enum _SaveStatus { none, saving, saved, failed }

/// One small piece of spoken translation (TTS) as KIT sent it.
class _TtsPart {
  _TtsPart({
    required this.index,
    required this.b64,
    required this.format,
    required this.rate,
    required this.start,
    required this.end,
  });
  final int index; // 1-based per language
  final String b64;
  final String? format; // field name, e.g. b64_enc_pcm_s16le
  final int? rate;
  final double? start; // seconds from session start
  final double? end;

  late final Uint8List bytes = base64Decode(b64);
  bool get isRiff =>
      bytes.length > 4 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;
  bool get isPcm {
    final f = (format ?? '').toLowerCase();
    return !isRiff && (f.contains('pcm') || f.contains('s16'));
  }

  int get sampleRate => rate ?? 16000;

  /// Playing time: from the PCM length when known, else KIT's timing.
  double get seconds {
    if (isPcm) return bytes.length / 2 / sampleRate;
    final s = start, e = end;
    return (s != null && e != null && e > s) ? e - s : 0;
  }
}

/// One output panel: the original transcript or one translation.
class _Lane {
  _Lane(this.key, this.title);
  final String key; // 'asr' or a language code
  final String title;
  final List<String> finals = <String>[];
  // Session-relative time span of each final (null when unknown).
  final List<double?> starts = <double?>[];
  final List<double?> ends = <double?>[];

  void addFinal(String text, [double? start, double? end]) {
    finals.add(text);
    starts.add(start);
    ends.add(end);
  }
  String pending = ''; // current unstable hypothesis
  final ScrollController scroll = ScrollController();

  String get fullText => joinFluent(finals);
  bool get isEmpty => finals.isEmpty && pending.isEmpty;
}

class LiveAsrScreen extends StatefulWidget {
  const LiveAsrScreen({super.key});

  @override
  State<LiveAsrScreen> createState() => _LiveAsrScreenState();
}

class _LiveAsrScreenState extends State<LiveAsrScreen>
    with UiModeListener<LiveAsrScreen> {
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

  // ─── Connection (UI lives in ServerConnectionPanel) ─────────────
  bool _isConnected = false;

  // ─── Session settings (same fields as the offline Job Settings) ───
  // In memory only — nothing here is persisted.
  final _formKey = GlobalKey<FormState>();
  final ExpansibleController _settingsTileController = ExpansibleController();
  // Mirrors the settings panel, so the language summary next to the mic
  // is only shown while the panel (with the same lists) is closed.
  bool _settingsOpen = false;
  void _onSettingsToggled() {
    final open = _settingsTileController.isExpanded;
    if (mounted && open != _settingsOpen) setState(() => _settingsOpen = open);
  }
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
  // No 'offline' here: with it KIT only processes after the recording
  // ends, so a live session shows nothing while speaking. Loaded settings
  // (video defaults / presets) with format 'offline' are therefore ignored.
  static const List<String> _formatOptions = [
    'online',
    'mixed',
    'resending',
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
  String? _outputSessionId; // KIT session id → Session Output files
  DateTime? _startedAt;

  double _level = 0;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _clock;

  // Audio upload queue (sequential, so chunks arrive in order).
  final List<Uint8List> _outbox = <Uint8List>[];
  bool _sending = false;

  // Output panels; key order = display order.
  final Map<String, _Lane> _lanes = <String, _Lane>{};

  // Live spoken translation (TTS): which language is heard, and the player.
  String? _ttsLane;
  final LiveTtsPlayer _tts = LiveTtsPlayer();

  // Link + QR for the audience: <server>/webapi/shorten/<permanent name>.
  // The name is the "Permanent Name" from the settings (like for videos).
  // Left empty: the email in the login token without "@", dots and other
  // non-alphanumerics (marcus.s@gmx.de → marcussgmxde); random only if
  // the token carries no email.
  String? _shareUrl;
  String _permanentName = ''; // the name actually sent to KIT

  static String _defaultPermanentName(String token) {
    final parts = token.split('|');
    final email = parts.length >= 3 && parts.last.contains('@')
        ? parts.last.trim().toLowerCase()
        : '';
    final name = email.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return name.isNotEmpty ? name : _randomPermanentName();
  }

  static String _randomPermanentName() {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789'; // no look-alikes
    final r = math.Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // Every TTS part as it arrives, per language (listed in the live screen,
  // each playable / downloadable right away).
  final Map<String, List<_TtsPart>> _ttsParts = <String, List<_TtsPart>>{};
  final LiveTtsPlayer _partPlayer = LiveTtsPlayer();
  String? _playingPart; // "<lane>#<index>"

  // Text spoken by the TTS part playing now: lane + time span.
  String? _hlLane;
  double? _hlStart, _hlEnd;
  bool _hlPinned = false; // set from the parts list: don't auto-scroll away

  void _highlight(String lane, double? start, double? end,
      {bool pinned = false, bool show = false}) {
    if (!mounted) return;
    setState(() {
      _hlLane = lane;
      _hlStart = start;
      _hlEnd = end;
      _hlPinned = pinned;
      if (show && _lanes.containsKey(lane)) _selectedLane = lane;
    });
    _scrollToHighlight();
  }

  void _clearHighlight(String lane, double? start) {
    if (!mounted || _hlLane != lane || _hlStart != start) return;
    setState(() {
      _hlLane = null;
      _hlStart = _hlEnd = null;
      _hlPinned = false;
    });
  }

  /// Indices of the finals that overlap the highlighted time span.
  Set<int> _highlightedFinals(_Lane lane) {
    final s = _hlStart, e = _hlEnd;
    if (lane.key != _hlLane || s == null) return const {};
    final end = (e == null || e < s) ? s : e;
    const tol = 0.15;
    final hit = <int>{};
    for (var i = 0; i < lane.finals.length; i++) {
      final fs = lane.starts[i], fe = lane.ends[i];
      if (fs == null) continue;
      final fEnd = fe ?? fs;
      if (fs < end - tol && fEnd > s + tol) hit.add(i);
    }
    if (hit.isEmpty) {
      // No overlap (e.g. very short part): take the final nearest in time.
      var best = -1;
      var bestD = double.infinity;
      for (var i = 0; i < lane.finals.length; i++) {
        final fs = lane.starts[i];
        if (fs == null) continue;
        final d = (fs - s).abs();
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      if (best >= 0 && bestD < 10) hit.add(best);
    }
    return hit;
  }

  void _scrollToHighlight() {
    final lane = _lanes[_hlLane];
    if (lane == null) return;
    final hit = _highlightedFinals(lane);
    if (hit.isEmpty) return;
    final first = hit.reduce(math.min);
    // Position of the highlight in the running text, as a fraction.
    var before = 0, total = 0;
    for (var i = 0; i < lane.finals.length; i++) {
      final n = lane.finals[i].length + 1;
      if (i < first) before += n;
      total += n;
    }
    final frac = total == 0 ? 0.0 : before / total;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sc = lane.scroll;
      if (!sc.hasClients) return;
      final max = sc.position.maxScrollExtent;
      final view = sc.position.viewportDimension;
      final target = (frac * (max + view) - view * 0.3).clamp(0.0, max);
      sc.animateTo(target,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }
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
    ServerConnection.tokenChanged.addListener(_checkConnection);
    ServerConnection.serverChanged.addListener(_checkConnection);
    _settingsTileController.addListener(_onSettingsToggled);
    // Tab closed / reloaded / navigated away while recording: Flutter's
    // dispose() never runs then, so tell the backend with a beacon (the
    // only request a closing page is guaranteed to get out).
    web.window.addEventListener('pagehide', _pageHideJs);
    _init();
  }

  late final JSFunction _pageHideJs =
      ((web.Event _) => _beaconStop()).toJS;

  void _beaconStop() {
    final id = _liveId;
    if (id == null ||
        !(_state == _LiveState.recording ||
            _state == _LiveState.starting ||
            _state == _LiveState.finishing)) {
      return;
    }
    try {
      // text/plain body: no CORS preflight, which beacons can't do.
      web.window.navigator.sendBeacon(
        '$flaskServerUrl/api/live/$id/stop',
        jsonEncode({'token': _token}).toJS,
      );
    } catch (e) {
      debugPrint('live stop beacon failed: $e');
    }
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
    await _loadLiveSettings();
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
    _settingsTileController.removeListener(_onSettingsToggled);
    web.window.removeEventListener('pagehide', _pageHideJs);
    _partPlayer.stop();
    ServerConnection.tokenChanged.removeListener(_checkConnection);
    ServerConnection.serverChanged.removeListener(_checkConnection);
    // Leaving the screen ends the session. Nothing is kept.
    _teardown(notifyServer: true);
    for (final l in _lanes.values) {
      l.scroll.dispose();
    }
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
  //  CONNECTION — the controls are in ServerConnectionPanel; this screen
  //  only needs to know whether a token exists (enables the mic button).
  // ═══════════════════════════════════════════════════════════════════
  Future<void> _checkConnection() async {
    final connected = await ServerConnection.isConnected();
    if (mounted) setState(() => _isConnected = connected);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LIVE SESSION
  // ═══════════════════════════════════════════════════════════════════

  /// The same fields the offline `/upload` sends, minus the video and
  /// the token. The relay forwards them to KIT unchanged.
  // ═══════════════════════════════════════════════════════════════════
  //  SAVED SETTINGS + PRESETS — same backend and same keys as the video
  //  Job Settings, so languages/options and presets are shared.
  // ═══════════════════════════════════════════════════════════════════

  /// Settings slot for live sessions (like a video key). With nothing
  /// saved yet the backend answers with the global defaults, exactly as
  /// for a new video.
  static const String _liveSettingsKey = '__live__';

  Map<String, dynamic> _currentSettingsMap() => <String, dynamic>{
        'input_languages': List<String>.from(_inputLanguages),
        'output_languages': List<String>.from(_outputLanguages),
        'audio_languages': List<String>.from(_audioLanguages),
        'availability': _availability,
        'format': _format,
        'smart_chaptering': _smartChaptering,
        'tts_quality_mode': _ttsQualityMode,
        'error_correction': _errorCorrection,
        'profanity_filter': _profanityFilter,
        'filter_music': _filterMusic,
        'summarization': _enableSummarization,
        'live_notes': _enableLiveNotes,
        'diarization': _enableDiarization,
        'ai_assistant': _enableAIAssistant,
        'save_session': _saveSession,
        'distinguish_unknown_speakers': _distinguishUnknownSpeakers,
        'postproduction': List<String>.from(_postproduction),
        'mute': _muteController.text,
        'pause': _pauseController.text,
        'speaker_name': _speakerNameController.text,
        'shorten': _shortenController.text,
        'saved_at': DateTime.now().toIso8601String(),
      };

  /// Apply a settings map (saved live settings, defaults or a preset).
  /// Missing keys keep their current value; unknown language codes are
  /// dropped.
  void _applySettingsMap(Map<String, dynamic> data) {
    void loadList(List<String> target, dynamic raw, List<String> valid) {
      if (raw is! List) return;
      target
        ..clear()
        ..addAll(raw.map((e) => e.toString()).where(valid.contains));
    }

    loadList(_inputLanguages, data['input_languages'],
        LanguageConfig.getSortedInputLanguages());
    loadList(_outputLanguages, data['output_languages'],
        LanguageConfig.getSortedOutputLanguages());
    loadList(_audioLanguages, data['audio_languages'],
        LanguageConfig.getSortedAudioLanguages());
    loadList(_postproduction, data['postproduction'], _postproductionOptions);

    String pick(dynamic v, List<String> options, String current) =>
        (v is String && options.contains(v)) ? v : current;
    _availability = pick(data['availability'], _availabilityOptions, _availability);
    _format = pick(data['format'], _formatOptions, _format);
    _smartChaptering =
        pick(data['smart_chaptering'], _chapteringOptions, _smartChaptering);
    _ttsQualityMode =
        pick(data['tts_quality_mode'], _ttsQualityOptions, _ttsQualityMode);
    _errorCorrection =
        pick(data['error_correction'], _errorCorrectionOptions, _errorCorrection);

    bool flag(dynamic v, bool current) => v is bool ? v : current;
    _profanityFilter = flag(data['profanity_filter'], _profanityFilter);
    _filterMusic = flag(data['filter_music'], _filterMusic);
    _enableSummarization = flag(data['summarization'], _enableSummarization);
    _enableLiveNotes = flag(data['live_notes'], _enableLiveNotes);
    _enableDiarization = flag(data['diarization'], _enableDiarization);
    _enableAIAssistant = flag(data['ai_assistant'], _enableAIAssistant);
    _saveSession = flag(data['save_session'], _saveSession);
    _distinguishUnknownSpeakers =
        flag(data['distinguish_unknown_speakers'], _distinguishUnknownSpeakers);

    if (data['mute'] is String) _muteController.text = data['mute'] as String;
    if (data['pause'] is String) _pauseController.text = data['pause'] as String;
    if (data['speaker_name'] is String) {
      _speakerNameController.text = data['speaker_name'] as String;
    }
    if (data['shorten'] is String) {
      _shortenController.text = data['shorten'] as String;
    }
    if (_inputLanguages.isEmpty) {
      final inputs = LanguageConfig.getSortedInputLanguages();
      if (inputs.isNotEmpty) _inputLanguages.add(inputs.first);
    }
  }

  Future<void> _loadLiveSettings() async {
    try {
      final resp = await http
          .get(Uri.parse(
              '$flaskServerUrl/video-job-settings/$_liveSettingsKey'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return;
      final parsed = jsonDecode(resp.body);
      if (parsed is Map && parsed.isNotEmpty && mounted) {
        setState(() => _applySettingsMap(parsed.cast<String, dynamic>()));
      }
    } catch (e) {
      debugPrint('loading live settings failed: $e');
    }
  }

  /// Remember the settings a live session was started with, so the next
  /// live session opens the same way.
  Future<void> _saveLiveSettings() async {
    try {
      await http
          .put(
            Uri.parse('$flaskServerUrl/video-job-settings/$_liveSettingsKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(_currentSettingsMap()),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('saving live settings failed: $e');
    }
  }

  Future<void> _saveCurrentAsPreset() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save as preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final resp = await http.post(
        Uri.parse('$flaskServerUrl/job-settings-presets'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'settings': _currentSettingsMap()}),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(resp.statusCode == 200
            ? 'Preset "$name" saved — also available for videos'
            : 'Failed: HTTP ${resp.statusCode}'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _loadPresetDialog() async {
    Map<String, dynamic> presets = {};
    try {
      final resp = await http
          .get(Uri.parse('$flaskServerUrl/job-settings-presets'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final raw = (jsonDecode(resp.body) as Map)['presets'];
        if (raw is Map) presets = raw.cast<String, dynamic>();
      }
    } catch (e) {
      debugPrint('load presets failed: $e');
    }
    if (!mounted) return;

    final names = presets.keys.toList()..sort();
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.download_outlined, color: Colors.blue),
            SizedBox(width: 8),
            Text('Load preset'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: names.isEmpty
              ? const Text('No presets saved yet. Presets saved for videos '
                  'or live sessions appear here.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in names)
                      ListTile(
                        leading: const Icon(Icons.bookmark_outline),
                        title: Text(n),
                        subtitle: Builder(builder: (_) {
                          final p = presets[n];
                          final outs = (p is Map && p['output_languages'] is List)
                              ? (p['output_languages'] as List).length
                              : 0;
                          return Text('$outs output languages');
                        }),
                        onTap: () => Navigator.pop(ctx, n),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    final p = chosen == null ? null : presets[chosen];
    if (p is Map && mounted) {
      setState(() => _applySettingsMap(p.cast<String, dynamic>()));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preset "$chosen" loaded')),
      );
    }
  }

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
    final sessionServer = internalServerUrl.replaceAll(RegExp(r'/+$'), '');
    final typedName = _shortenController.text.trim();
    final permanentName =
        typedName.isNotEmpty ? typedName : _defaultPermanentName(token);
    _saveLiveSettings(); // next live session opens with these settings

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
          'settings': {..._settingsPayload(), 'shorten': permanentName},
        }),
      );
      final body = _tryJson(resp.body);
      if (resp.statusCode != 200 || body?['live_id'] == null) {
        if (resp.statusCode == 401) await _checkConnection();
        throw Exception(body?['error'] ?? 'HTTP ${resp.statusCode}');
      }
      _liveId = body!['live_id'] as String;
      _savedId = _liveId;
      _outputSessionId = body['session_id']?.toString();
      _shareUrl = '$sessionServer/webapi/shorten/$permanentName';
      _permanentName = permanentName;
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
          l.addFinal(l.pending);
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
            text: joinFluent([...l.finals, l.pending]),
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
        // Store the permanent name actually used (also when it was the
        // default from the email), so the list can show it.
        settings: {
          ..._settingsPayload(),
          if (_permanentName.isNotEmpty) 'shorten': _permanentName,
        },
        lanes: lanes,
        outputSessionId: _outputSessionId,
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
    _tts.stop();
    _ttsLane = null;
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

  // ─── TTS parts ───────────────────────────────────────────────────
  Future<void> _playPart(String lane, _TtsPart p) async {
    final id = '$lane#${p.index}';
    await _partPlayer.stop();
    if (_playingPart == id) {
      setState(() => _playingPart = null); // second tap = stop
      _clearHighlight(lane, p.start);
      return;
    }
    await _partPlayer.unlock();
    // Show the translation this part speaks, highlighted.
    _highlight(lane, p.start, p.end, pinned: true, show: true);
    _partPlayer.enqueue(
      p.b64,
      format: p.format,
      rate: p.rate,
      onEnd: () {
        if (!mounted || _playingPart != id) return;
        setState(() => _playingPart = null);
        _clearHighlight(lane, p.start);
      },
    );
    setState(() => _playingPart = id);
  }

  /// WAV file for PCM parts (16-bit mono); other formats as they came.
  static Uint8List _wavFromPcm(List<Uint8List> pcm, int rate) {
    final dataLen = pcm.fold<int>(0, (n, b) => n + b.length);
    final out = BytesBuilder(copy: false);
    final h = ByteData(44);
    void str(int o, String v) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(o + i, v.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    h.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, 1, Endian.little); // mono
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    str(36, 'data');
    h.setUint32(40, dataLen, Endian.little);
    out.add(h.buffer.asUint8List());
    for (final b in pcm) {
      out.add(b);
    }
    return out.toBytes();
  }

  static String _extFor(Uint8List b) {
    if (b.length > 4 && b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67) return 'ogg';
    if (b.length > 3 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return 'mp3';
    if (b.length > 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return 'mp3';
    if (b.length > 4 && b[0] == 0x1A && b[1] == 0x45) return 'webm';
    return 'wav';
  }

  void _saveBytes(Uint8List bytes, String fileName, String mime) {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    (web.HTMLAnchorElement()
          ..href = url
          ..download = fileName)
        .click();
    web.URL.revokeObjectURL(url);
  }

  String get _fileBase {
    final n = _sessionNameController.text.trim();
    return n.isEmpty ? _defaultSessionName() : n;
  }

  void _downloadPart(String lane, _TtsPart p) {
    final nr = p.index.toString().padLeft(3, '0');
    if (p.isPcm) {
      _saveBytes(_wavFromPcm([p.bytes], p.sampleRate),
          '${_fileBase}_tts_${lane}_$nr.wav', 'audio/wav');
    } else {
      final ext = _extFor(p.bytes);
      _saveBytes(p.bytes, '${_fileBase}_tts_${lane}_$nr.$ext', 'audio/$ext');
    }
  }

  /// All parts of one language back to back in one WAV (PCM parts).
  void _downloadAllParts(String lane) {
    final parts = _ttsParts[lane] ?? const <_TtsPart>[];
    final pcm = parts.where((p) => p.isPcm).toList();
    if (pcm.isEmpty) {
      for (final p in parts) {
        _downloadPart(lane, p);
      }
      return;
    }
    _saveBytes(
      _wavFromPcm([for (final p in pcm) p.bytes], pcm.first.sampleRate),
      '${_fileBase}_tts_${lane}_all.wav',
      'audio/wav',
    );
  }

  static String _partTime(double? s) {
    if (s == null) return '–';
    final t = s < 0 ? 0.0 : s;
    final m = t ~/ 60;
    final sec = t - m * 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(1).padLeft(4, '0')}';
  }

  Widget _buildTtsParts(BuildContext c) {
    final langs = _ttsParts.keys.toList()
      ..sort((a, b) => _laneTitle(a).compareTo(_laneTitle(b)));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.graphic_eq, size: 18, color: Colors.grey.shade700),
              const SizedBox(width: 6),
              Text('Spoken translation parts',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: _bodySize(c))),
            ]),
            for (final lane in langs) _buildTtsLaneParts(lane),
          ],
        ),
      ),
    );
  }

  Widget _buildTtsLaneParts(String lane) {
    final parts = _ttsParts[lane]!;
    final total = parts.fold<double>(0, (n, p) => n + p.seconds);
    return ExpansionTile(
      key: PageStorageKey('tts-parts-$lane'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.only(bottom: 6),
      dense: true,
      title: Text(_laneTitle(lane)),
      subtitle: Text(
          '${parts.length} part${parts.length == 1 ? '' : 's'} · '
          '${total.toStringAsFixed(1)} s',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Download all parts as one WAV',
          icon: const Icon(Icons.download, size: 20),
          onPressed: () => _downloadAllParts(lane),
        ),
        const Icon(Icons.expand_more),
      ]),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            // Newest first, so new parts appear at the top as they come.
            itemCount: parts.length,
            itemBuilder: (_, i) {
              final p = parts[parts.length - 1 - i];
              final playing = _playingPart == '$lane#${p.index}';
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: IconButton(
                  tooltip: playing ? 'Stop' : 'Play',
                  icon: Icon(playing ? Icons.stop_circle : Icons.play_circle,
                      color: Colors.blue.shade700),
                  onPressed: () => _playPart(lane, p),
                ),
                // Tap the row = find its text (highlight for a few seconds).
                onTap: () {
                  _highlight(lane, p.start, p.end, pinned: true, show: true);
                  Future<void>.delayed(const Duration(seconds: 8), () {
                    if (_playingPart != '$lane#${p.index}') {
                      _clearHighlight(lane, p.start);
                    }
                  });
                },
                title: Text(
                  '#${p.index}   ${_partTime(p.start)} – ${_partTime(p.end)}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
                subtitle: Text('${p.seconds.toStringAsFixed(1)} s'),
                trailing: IconButton(
                  tooltip: 'Download this part',
                  icon: const Icon(Icons.file_download_outlined, size: 20),
                  onPressed: () => _downloadPart(lane, p),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _newSession() {
    final old = _lanes.values.map((l) => l.scroll).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final s in old) {
        s.dispose();
      }
    });
    _partPlayer.stop();
    setState(() {
      _lanes.clear();
      _ttsParts.clear();
      _playingPart = null;
      _hlLane = null;
      _hlStart = _hlEnd = null;
      _hlPinned = false;
      _error = null;
      _state = _LiveState.idle;
      _stopwatch.reset();
      _saveStatus = _SaveStatus.none;
      _saveError = null;
      _savedId = null;
      _outputSessionId = null;
      _shareUrl = null;
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
    // The relay has identified a stream's language: move what was shown
    // under the temporary panel (e.g. "Translation (mt:2)") into it.
    if (msg['_relabel'] == true) {
      _mergeLane(
        msg['from']?.toString() ?? '',
        (msg['to']?.toString() ?? '').toLowerCase(),
      );
      return;
    }

    // Spoken translation: every part is listed; the language being
    // listened to is also played aloud.
    if (msg['_tts'] == true) {
      final audio = msg['audio']?.toString();
      if (audio == null || audio.isEmpty) return;
      final lane = (msg['_lane'] ?? 'tts').toString().toLowerCase();
      final format = msg['format']?.toString();
      final rate = (msg['rate'] as num?)?.toInt();
      setState(() {
        final list = _ttsParts.putIfAbsent(lane, () => <_TtsPart>[]);
        list.add(_TtsPart(
          index: list.length + 1,
          b64: audio,
          format: format,
          rate: rate,
          start: (msg['start'] as num?)?.toDouble(),
          end: (msg['end'] as num?)?.toDouble(),
        ));
      });
      final listen = msg.containsKey('listen')
          ? msg['listen'] == true
          : lane == _ttsLane; // older relay: only the heard language came
      if (listen && lane == _ttsLane) {
        final st = (msg['start'] as num?)?.toDouble();
        final en = (msg['end'] as num?)?.toDouble();
        _tts.enqueue(
          audio,
          format: format,
          rate: rate,
          onStart: () {
            if (!_hlPinned) _highlight(lane, st, en);
          },
          onEnd: () {
            if (!_hlPinned) _clearHighlight(lane, st);
          },
        );
      }
      return;
    }

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

    // The relay resolves the language (SSE event name, language field,
    // sender) and sends it as `_lane`; older relays don't, so fall back.
    final relayLane = msg['_lane']?.toString();
    final laneKey = (relayLane != null && relayLane.isNotEmpty)
        ? relayLane.toLowerCase()
        : _laneKeyForSender(sender, msg);
    if (laneKey == null) return;
    // Every translation gets a panel, even one that was not pre-selected
    // or whose language KIT does not name.
    final lane = _lanes.putIfAbsent(laneKey, () => _Lane(laneKey, _laneTitle(laneKey)));

    final unstable = msg['unstable'] == true;
    setState(() {
      if (unstable) {
        lane.pending = text;
      } else {
        lane.addFinal(
          text,
          (msg['_start'] as num?)?.toDouble(),
          (msg['_end'] as num?)?.toDouble(),
        );
        lane.pending = '';
      }
    });
    if (!(_hlPinned && _hlLane == laneKey)) _scrollToEnd(lane);
  }

  /// Switch the spoken translation heard live (null = off). Called from a
  /// tap, which also lets the browser start audio.
  Future<void> _selectTts(String? lane) async {
    await _tts.stop();
    setState(() => _ttsLane = lane);
    if (lane != null) await _tts.unlock();
    final id = _liveId;
    if (id == null) return;
    try {
      await http.post(
        Uri.parse('$flaskServerUrl/api/live/$id/tts'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({'lane': lane}),
      );
    } catch (e) {
      debugPrint('live TTS select failed: $e');
    }
  }

  /// Panels: original first, then languages A→Z, unidentified last.
  List<_Lane> _sortedLanes() {
    int group(_Lane l) => l.key == 'asr'
        ? 0
        : (RegExp(r'^[a-z]{2,3}$').hasMatch(l.key) ? 1 : 2);
    final list = _lanes.values.toList()
      ..sort((a, b) {
        final g = group(a).compareTo(group(b));
        return g != 0 ? g : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    return list;
  }

  Widget _buildTtsSelector(BuildContext c) {
    final langs = [..._audioLanguages]
      ..sort((a, b) => LanguageConfig.getDisplayName(a)
          .compareTo(LanguageConfig.getDisplayName(b)));
    final live = _state == _LiveState.recording;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.record_voice_over,
                    size: 18, color: Colors.grey.shade700),
                Text(
                  'Spoken translation:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: _bodySize(c),
                  ),
                ),
                ChoiceChip(
                  label: const Text('Off'),
                  selected: _ttsLane == null,
                  onSelected: live ? (_) => _selectTts(null) : null,
                  visualDensity: VisualDensity.compact,
                ),
                for (final code in langs)
                  ChoiceChip(
                    avatar: _ttsLane == code
                        ? const Icon(Icons.volume_up, size: 16)
                        : null,
                    label: Text(LanguageConfig.getDisplayName(code)),
                    selected: _ttsLane == code,
                    onSelected: live ? (_) => _selectTts(code) : null,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (_ttsLane != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Use headphones, so the microphone does not pick up the '
                  'spoken translation.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _mergeLane(String from, String to) {
    if (from.isEmpty || to.isEmpty || from == to) return;
    final src = _lanes.remove(from);
    if (src == null) return;
    setState(() {
      final dst = _lanes.putIfAbsent(to, () => _Lane(to, _laneTitle(to)));
      // The temporary panel's lines came first.
      dst.finals.insertAll(0, src.finals);
      dst.starts.insertAll(0, src.starts);
      dst.ends.insertAll(0, src.ends);
      if (dst.pending.isEmpty) dst.pending = src.pending;
      if (_selectedLane == from) _selectedLane = to;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => src.scroll.dispose());
  }

  String _laneTitle(String key) {
    if (key == 'asr') {
      return 'Original · '
          '${_inputLanguages.map(LanguageConfig.getDisplayName).join(', ')}';
    }
    if (RegExp(r'^[a-z]{2,3}$').hasMatch(key)) {
      return LanguageConfig.getDisplayName(key);
    }
    return 'Translation ($key)';
  }

  Future<void> _openFullOutput() async {
    final id = _outputSessionId;
    if (id == null || id.isEmpty) return;
    await AppUrl.set(AppUrl.live, id);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionOutputScreen(sessionId: id, sessionUrl: ''),
      ),
    );
    await AppUrl.set(AppUrl.live, 'new');
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

  bool get _hasOutput =>
      _lanes.values.any((l) => !l.isEmpty) || _ttsParts.isNotEmpty;

  /// Empties the panels and the TTS parts list (the session keeps running).
  Future<void> _clearOutput() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the output?'),
        content: Text(_state == _LiveState.recording
            ? 'The text and spoken-translation parts shown so far are removed '
                'from this screen. The session keeps running; new text appears '
                'as usual. The transcript saved at the end will only contain '
                'what comes after this.'
            : 'The text and spoken-translation parts are removed from this '
                'screen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _partPlayer.stop();
    setState(() {
      for (final l in _lanes.values) {
        l.finals.clear();
        l.starts.clear();
        l.ends.clear();
        l.pending = '';
      }
      _ttsParts.clear();
      _playingPart = null;
      _hlLane = null;
      _hlStart = _hlEnd = null;
      _hlPinned = false;
    });
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
              l.addFinal(l.pending);
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
          actions: const [UiModeToggle()],
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
                // ─── 1. Server + connection (top of every page) ───
                ServerConnectionPanel(enabled: !_isActive),
                SizedBox(height: gap),

                // ─── QR code + link for the audience ───
                if (_shareUrl != null && _state != _LiveState.idle) ...[
                  SessionShareCard(
                    url: _shareUrl!,
                    fileBaseName: _fileBase,
                  ),
                  SizedBox(height: gap),
                ],

                // ─── 2. Microphone ───
                _buildControlBar(context),
                if (_audioLanguages.isNotEmpty &&
                    (_state == _LiveState.recording ||
                        _state == _LiveState.finishing)) ...[
                  const SizedBox(height: 8),
                  _buildTtsSelector(context),
                ],
                if (_ttsParts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildTtsParts(context),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  _buildErrorBanner(),
                ],
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
  /// "German, English → English, Russian" and "TTS: English, Russian".
  Widget _languageSummary(BuildContext c) {
    String names(List<String> codes) =>
        codes.map(LanguageConfig.getDisplayName).join(', ');
    final style =
        TextStyle(fontSize: _bodySize(c) - 1, color: Colors.grey.shade700);
    Widget item(IconData icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 14, color: Colors.grey.shade600),
            ),
            const SizedBox(width: 4),
            Flexible(child: Text(text, style: style)),
          ],
        );
    return Wrap(
      spacing: 14,
      runSpacing: 2,
      children: [
        if (_inputLanguages.isNotEmpty)
          item(
            Icons.translate,
            _outputLanguages.isEmpty
                ? names(_inputLanguages)
                : '${names(_inputLanguages)}  →  ${names(_outputLanguages)}',
          ),
        if (_audioLanguages.isNotEmpty)
          item(Icons.record_voice_over_outlined,
              'TTS: ${names(_audioLanguages)}'),
      ],
    );
  }

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
            : 'Connect to the server above to start';
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
                  // Microphone level — only while there is a microphone.
                  if (_state != _LiveState.idle) ...[
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
                  ],
                  // Languages at a glance — not while the open settings
                  // panel below already shows the same lists.
                  if (!_settingsOpen || _isActive) ...[
                    const SizedBox(height: 6),
                    _languageSummary(c),
                  ],
                ],
              ),
            ),
            if (_state != _LiveState.idle && _hasOutput) ...[
              const SizedBox(width: 12),
              Tooltip(
                message: 'Remove the text and spoken-translation parts '
                    'shown so far',
                child: _isNarrow(c)
                    ? IconButton.outlined(
                        onPressed: _clearOutput,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                      )
                    : OutlinedButton.icon(
                        onPressed: _clearOutput,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Clear output'),
                      ),
              ),
            ],
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
            if (_state == _LiveState.finished &&
                _saveStatus == _SaveStatus.saved &&
                (_outputSessionId ?? '').isNotEmpty) ...[
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _openFullOutput,
                icon: const Icon(Icons.subtitles, size: 18),
                label: Text(_isNarrow(c) ? 'Output' : 'Open output'),
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
              Text(
                UiMode.isExpert ? 'Live Session Settings' : 'Languages',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
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
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadPresetDialog,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Load preset'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _saveCurrentAsPreset,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: const Text('Save as preset'),
                  ),
                  TextButton.icon(
                    onPressed: () => _settingsTileController.collapse(),
                    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    label: const Text('Collapse'),
                  ),
                ],
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

    // Simple mode: only the languages. Everything else keeps its
    // current value and is still sent to KIT.
    if (UiMode.isSimple) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLanguageBlock(
            title: 'Spoken languages',
            availableCodes: inputLangCodes,
            selected: _inputLanguages,
            nameFor: LanguageConfig.getInputLanguageName,
            onToggle: (c) => toggle(_inputLanguages, c),
            onReplaceAll: (l) => replace(_inputLanguages, l),
          ),
          const SizedBox(height: 16),
          _buildLanguageBlock(
            title: 'Translate into',
            availableCodes: outputLangCodes,
            selected: _outputLanguages,
            nameFor: LanguageConfig.getOutputLanguageName,
            onToggle: (c) => toggle(_outputLanguages, c),
            onReplaceAll: (l) => replace(_outputLanguages, l),
          ),
          const SizedBox(height: 16),
          _buildLanguageBlock(
            title: 'Generated audio (spoken translation)',
            availableCodes: audioLangCodes,
            selected: _audioLanguages,
            nameFor: LanguageConfig.getAudioLanguageName,
            onToggle: (c) => toggle(_audioLanguages, c),
            onReplaceAll: (l) => replace(_audioLanguages, l),
          ),
          const SizedBox(height: 8),
          Text(
            'More options (session name, availability, features …) '
            'in Expert mode.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      );
    }

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
            hintText: 'Leave empty: your email without @ and dots',
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

  /// Chosen languages visible; all others in a collapsed list.
  Widget _buildLanguageBlock({
    required String title,
    required List<String> availableCodes,
    required List<String> selected,
    required String Function(String code) nameFor,
    required void Function(String code) onToggle,
    required void Function(List<String>) onReplaceAll,
  }) {
    return LanguagePicker(
      title: title,
      availableCodes: availableCodes,
      selected: selected,
      nameFor: nameFor,
      onToggle: onToggle,
      onReplaceAll: onReplaceAll,
      titleSize: _bodySize(context),
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

    final lanes = _sortedLanes();

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

  /// Running text; the part a TTS chunk is speaking is highlighted.
  List<InlineSpan> _finalSpans(_Lane lane) {
    final hit = _highlightedFinals(lane);
    if (hit.isEmpty) return [TextSpan(text: lane.fullText)];
    final spans = <InlineSpan>[];
    final buf = <String>[];
    bool? bufHi;
    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(
        text: joinFluent(buf),
        style: bufHi == true
            ? TextStyle(
                backgroundColor: Colors.amber.shade200,
                color: Colors.black,
              )
            : null,
      ));
      buf.clear();
    }

    for (var i = 0; i < lane.finals.length; i++) {
      final hi = hit.contains(i);
      if (bufHi != null && hi != bufHi) {
        flush();
        spans.add(const TextSpan(text: ' '));
      }
      bufHi = hi;
      buf.add(lane.finals[i]);
    }
    flush();
    return spans;
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
                        // Running text: finished segments flow on in one
                        // paragraph, the still-changing part follows in grey.
                        Text.rich(
                          TextSpan(
                            style: TextStyle(fontSize: textSize, height: 1.4),
                            children: [
                              ..._finalSpans(lane),
                              if (lane.pending.isNotEmpty)
                                TextSpan(
                                  text: (lane.finals.isEmpty ? '' : ' ') +
                                      lane.pending.trim(),
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                            ],
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
