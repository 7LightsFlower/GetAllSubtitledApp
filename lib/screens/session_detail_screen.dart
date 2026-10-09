// session_detail_screen.dart  (merged with job_configuration_screen.dart)
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/screens/session_output_screen.dart';
import 'package:asr_live_translator/theme/responsive.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:asr_live_translator/widgets/job_progress_panel.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart'; // LogicalKeyboardKey
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:asr_live_translator/widgets/video_player_widget.dart';

// ═══════════════════════════════════════════════════════════════════
//  DATA MODELS
// ═══════════════════════════════════════════════════════════════════

class SessionDetail {
  final String key;
  final String name;
  final String fileName;
  final DateTime uploaded;
  final DateTime? lastOpened;
  final double duration;
  final double fps;
  final int fileSize;
  final int segmentCount;
  final List<String> languages;
  final String? thumbnailUrl;
  final String? videoUrl;
  final List<Segment> segments;
  
  // Green-screen metadata (populated once the backend has built one).
  final int greenscreenFileSize;      // 0 until ready
  final DateTime? greenscreenCreatedAt;  // null until ready
  final String greenscreenStatus;     // pending | building | ready | failed

  // identity of the last job run for this video
  final List<Map<String, dynamic>> jobHistory;

  SessionDetail({
    required this.key,
    required this.name,
    required this.fileName,
    required this.uploaded,
    this.lastOpened,
    required this.duration,
    required this.fps,
    required this.fileSize,
    required this.segmentCount,
    required this.languages,
    this.thumbnailUrl,
    this.videoUrl,
    required this.segments,
    this.greenscreenFileSize = 0,
    this.greenscreenCreatedAt,
    this.greenscreenStatus = 'pending',
    this.jobHistory = const [],
  });

  static DateTime _parseDateTime(String dateStr) {
    try {
      return DateTime.parse(dateStr).toLocal();
    } catch (_) {
      final cleaned = dateStr.replaceFirst(RegExp(r'\+00:00(?=Z)'), '');
      try {
        return DateTime.parse(cleaned).toLocal();
      } catch (_) {
        return DateTime.now();
      }
    }
  }


  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final segments = (json['segments'] as List?)
            ?.map((e) => Segment.fromJson(e))
            .toList() ??
        [];
    return SessionDetail(
      key: json['key'] as String,
      name: json['name'] as String? ?? 'Untitled',
      fileName: json['file_name'] as String? ?? 'video.mp4',
      uploaded: _parseDateTime(json['uploaded'] as String),
      lastOpened: json['last_opened'] != null
          ? _parseDateTime(json['last_opened'] as String)
          : null,
      greenscreenCreatedAt: json['greenscreen_created_at'] != null
          ? _parseDateTime(json['greenscreen_created_at'] as String)
          : null,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      fileSize: json['file_size'] as int? ?? 0,
      segmentCount: json['segment_count'] as int? ?? 0,
      languages: (json['languages'] as List?)?.cast<String>() ?? [],
      thumbnailUrl: json['thumbnail_url'] as String?,
      videoUrl: json['video_url'] as String?,
      segments: segments,
            greenscreenFileSize: json['greenscreen_file_size'] as int? ?? 0,
      greenscreenStatus:
          json['greenscreen_status'] as String? ?? 'pending',
      jobHistory: (json['job_history'] as List?)
              ?.whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList() ??
          const [],
    );
  }
}

class Segment {
  final int id;
  final double start;
  final double end;
  final String? language;
  final String? url;

  Segment({
    required this.id,
    required this.start,
    required this.end,
    this.language,
    this.url,
  });

  factory Segment.fromJson(Map<String, dynamic> json) {
    return Segment(
      id: json['id'] as int? ?? 0,
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
      language: json['language'] as String?,
      url: json['url'] as String?,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  SCREEN
// ═══════════════════════════════════════════════════════════════════

class LiveTranscriptScreen extends StatefulWidget {
  final String videoKey;

  const LiveTranscriptScreen({super.key, required this.videoKey});

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
    // ─────────────────────────────────────────────────────────────
  //  RESPONSIVE HELPERS
  // ─────────────────────────────────────────────────────────────
  //
  // Three breakpoints, matching what the rest of the app uses:
  //   narrow   < 600 dp      (phones)
  //   medium   600 – 999 dp  (tablets, small windows)
  //   wide    ≥ 1000 dp      (desktop)
  //
  // Using MediaQuery.sizeOf() rather than MediaQuery.of() so the widget
  // only rebuilds when the *size* changes, not on every unrelated
  // MediaQueryData change (keyboard, brightness, …).

  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;
  bool _isMedium(BuildContext c) {
    final w = MediaQuery.sizeOf(c).width;
    return w >= 600 && w < 1000;
  }

  /// Horizontal / vertical page padding. Was a hard-coded 16.
  double _pagePadding(BuildContext c) {
    if (_isNarrow(c)) return 12;
    if (_isMedium(c)) return 16;
    return 24;
  }

  /// Vertical gap between the top-level cards. Was a hard-coded 16.
  double _sectionGap(BuildContext c) {
    if (_isNarrow(c)) return 12;
    if (_isMedium(c)) return 16;
    return 24;
  }

  /// Body font size scaled by breakpoint.
  double _bodySize(BuildContext c) {
    if (_isNarrow(c)) return 13;
    if (_isMedium(c)) return 14;
    return 14;
  }

  /// Title font size (video title, section headings).
  double _titleSize(BuildContext c) {
    if (_isNarrow(c)) return 17;
    if (_isMedium(c)) return 19;
    return 20;
  }

  // ─── Session detail state ────────────────────────────────────────
  SessionDetail? _detail;
  bool _isLoadingDetail = true;
  String? _detailError;

  VideoPlayerController? _videoController;
  bool _isVideoReady = false;

  // ─── Persistence keys for Job Settings ──────────────────────────

  // Per-video SharedPreferences key. Was a single global key
  // ('job_settings_defaults_v1'), which meant the last-saved block for
  // *any* video was used as the fallback for every video that had no
  // server-side settings file yet. That's why a freshly imported video
  // showed the previous video's session name and languages.
  String get _settingsKey => 'job_settings_${widget.videoKey}';

  // ─── Job configuration state ─────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sessionNameController;
  final TextEditingController _topicNameController = TextEditingController();
  final TextEditingController _speakerNameController = TextEditingController();
  final TextEditingController _shortenController = TextEditingController();
  final TextEditingController _muteController =
      TextEditingController(text: '120');
  final TextEditingController _pauseController =
      TextEditingController(text: '2');

  String _date = '';

  // Language lists using ISO 639-1 codes from LanguageConfig
  final List<String> _inputLanguages = ['en','de'];
  final List<String> _outputLanguages = ['en','de'];
  final List<String> _audioLanguages = <String>[];

  String _availability = 'private';
  bool _profanityFilter = true;
  bool _filterMusic = true;
  bool _enableSummarization = true;
  bool _enableLiveNotes = false;
  bool _enableDiarization = false;
  bool _enableAIAssistant = false;
  bool _saveSession = true;
  bool _distinguishUnknownSpeakers = false;
  String _smartChaptering = 'online_dynamic';
  String _format = 'mixed';
  String _ttsQualityMode = 'low_latency';
  String _errorCorrection = 'None';
  final List<String> _postproduction = <String>[];
  bool _isSubmitting = false;
  bool _isConnected = false;
  bool _isConnecting = false;

  // Manual token state
  bool _showTokenInput = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

  // Bookmarklet state
  bool _showBookmarklet = false;

  // Response display state
  String _responseMessage = '';
  String _responseHtml = '';
  String _sessionUrl = '';
  String _sessionId = '';
  String _videoKeyResponse = '';
  bool _showResponse = false;

  // Output checking state
  bool _hasSessionId = false;
  String _savedSessionId = '';
  String _savedSessionUrl = '';
  bool _isCheckingOutput = false;
  bool _isCancelling = false; 
  String _outputStatus = '';

  // Job history
  List<Map<String, dynamic>> _jobHistory = [];
  bool _isLoadingHistory = false;

  // Controllers so we can collapse the Job History / Job Settings
  // ExpansionTiles from a button at the bottom of their content, not
  // just by tapping the header.
  final ExpansibleController _jobHistoryTileController =
      ExpansibleController();
  final ExpansibleController _jobSettingsTileController =
      ExpansibleController();
  // ─── Constants ───────────────────────────────────────────────────
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

  // Bookmarklet: one click on the /gettoken page copies the token to clipboard.
  static const String _bookmarkletJs =
      "javascript:(function(){"
      "const pre=document.querySelector('pre');"
      "if(!pre){alert('Not on the /gettoken page');return;}"
      "const t=pre.textContent.trim();"
      "navigator.clipboard.writeText(t).then("
      "()=>alert('Token copied \u2014 go back to the app and click \"Paste Token\"'),"
      "()=>prompt('Copy manually:',t)"
      ");"
      "})();";

  Timer? _autoCheckTimer;

  // Debounce for pushing the current Job Settings to the backend.
  // Cancelled on dispose and re-armed on every field change, so a
  // burst of typing produces a single PUT.
  Timer? _settingsPushDebounce;

  // ─── Init ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _sessionNameController = TextEditingController();
    final now = DateTime.now();
    _date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _purgeLegacySettingsKey(); 
    _initServerConfig(); 
    _loadJobSettings();   
    _checkConnection();
    _loadJobHistory().then((_) => _loadSavedSessionId());
    _fetchDetail();
    _registerDeepLink();

    // Poll the job status every 30 s while any job is still "Processing".
    _autoCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final idx = _jobHistory
          .indexWhere((j) => j['session_id'] == _savedSessionId);
      if (idx == -1) return;
      final status = _jobHistory[idx]['status'] as String? ?? '';
      final hasOutput = _jobHistory[idx]['has_output'] as bool? ?? false;
      if (!hasOutput && status.contains('Processing')) {
        _checkOutput();
      }
    });
  }

  /// One-time cleanup of the key used by the pre-per-video settings
  /// implementation. Runs once per screen mount; a no-op after the
  /// first run.
  Future<void> _purgeLegacySettingsKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('job_settings_defaults_v1')) {
        await prefs.remove('job_settings_defaults_v1');
        debugPrint('Removed legacy global settings key');
      }
    } catch (e) {
      debugPrint('legacy settings cleanup failed: $e');
    }
  }

  Future<void> _initServerConfig() async {
    await ServerConfigService.load();
    if (mounted) setState(() {});
  }

  /// Extract the email from a LT KIT bearer token.
  ///
  /// Token format: `<opaque>|<expiry>|<email>`.
  // ignore: unused_element
  String _emailFromToken(String token) {
    final parts = token.split('|');
    if (parts.length >= 3) {
      final email = parts.last.trim();
      if (email.contains('@')) return email;
    }
    return 'admin@example.com';  // legacy fallback
  }  

  /// Read the login email out of the stored bearer token.
  ///
  /// KIT tokens look like `<opaque>|<expiry>|<email>`. Returns an
  /// empty string when the token is missing or malformed, so the UI
  /// can render "—" without special-casing.
  Future<String> _tokenEmail() async {
    final token = await InternalAuthService.getToken();
    if (token == null || token.isEmpty) return '';
    final parts = token.split('|');
    if (parts.length >= 3) {
      final email = parts.last.trim();
      if (email.contains('@')) return email;
    }
    return '';
  }

  /// Reflect the current video on the URL bar, so the page can be
  /// bookmarked or shared as a single clickable link.
  ///
  /// Route shape:  /session-detail/<video_key>
  void _registerDeepLink() {
    try {
      final desiredPath = '/session-detail/${widget.videoKey}';
      if (html.window.location.pathname != desiredPath) {
        html.window.history.replaceState(
          null,
          'Session Detail',
          desiredPath,
        );
      }
    } catch (e) {
      debugPrint('deep-link update failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  JOB SETTINGS PERSISTENCE
  // ═══════════════════════════════════════════════════════════════════
  /// Everything the user can currently see in the Job Settings panel,
  /// as a JSON-serialisable map. This is the object we persist.
  Map<String, dynamic> _currentSettingsMap() {
    return {
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
      'session_name': _sessionNameController.text,
      'topic_name': _topicNameController.text,
      'speaker_name': _speakerNameController.text,
      'shorten': _shortenController.text,
      'date': _date,
      'saved_at': DateTime.now().toIso8601String(),
    };
  }

  /// Apply a settings map to every field in the Job Settings panel.
  /// Missing / null keys leave the current value untouched.
  void _applySettingsMap(Map<String, dynamic> data) {
    void loadList(List<String> target, dynamic raw, List<String> fallback) {
      target.clear();
      if (raw is List) {
        target.addAll(raw.map((e) => e.toString()));
      } else {
        target.addAll(fallback);
      }
    }

    _inputLanguages.clear();
    _outputLanguages.clear();
    _audioLanguages.clear();
    _postproduction.clear();

    loadList(_inputLanguages, data['input_languages'], ['en']);
    loadList(_outputLanguages, data['output_languages'], ['de']);
    loadList(_audioLanguages, data['audio_languages'], const []);
    loadList(_postproduction, data['postproduction'], const []);

    _availability    = data['availability']     as String? ?? _availability;
    _format          = data['format']           as String? ?? _format;
    _smartChaptering = data['smart_chaptering'] as String? ?? _smartChaptering;
    _ttsQualityMode  = data['tts_quality_mode'] as String? ?? _ttsQualityMode;
    _errorCorrection = data['error_correction'] as String? ?? _errorCorrection;

    _profanityFilter     = data['profanity_filter'] as bool? ?? _profanityFilter;
    _filterMusic         = data['filter_music']     as bool? ?? _filterMusic;
    _enableSummarization = data['summarization']    as bool? ?? _enableSummarization;
    _enableLiveNotes     = data['live_notes']       as bool? ?? _enableLiveNotes;
    _enableDiarization   = data['diarization']      as bool? ?? _enableDiarization;
    _enableAIAssistant   = data['ai_assistant']     as bool? ?? _enableAIAssistant;
    _saveSession         = data['save_session']     as bool? ?? _saveSession;
    _distinguishUnknownSpeakers =
        data['distinguish_unknown_speakers'] as bool? ?? _distinguishUnknownSpeakers;

    _muteController.text  = data['mute']  as String? ?? _muteController.text;
    _pauseController.text = data['pause'] as String? ?? _pauseController.text;

    final sn = data['session_name'];
    if (sn is String && sn.isNotEmpty) _sessionNameController.text = sn;
    final tn = data['topic_name'];
    if (tn is String) _topicNameController.text = tn;
    final spn = data['speaker_name'];
    if (spn is String) _speakerNameController.text = spn;
    final sh = data['shorten'];
    if (sh is String) _shortenController.text = sh;
    final dt = data['date'];
    if (dt is String && dt.isNotEmpty) _date = dt;
  }

  Future<void> _loadJobSettings() async {
    Map<String, dynamic>? data;

    // 1. Server-side file (per video).
    try {
      final resp = await http
          .get(Uri.parse(
              '$flaskServerUrl/video-job-settings/${widget.videoKey}'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map && parsed.isNotEmpty) {
          data = parsed.cast<String, dynamic>();
        }
      }
    } catch (e) {
      debugPrint('server load settings failed: $e');
    }

    // 2. Local fallback — now per video.
    if (data == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_settingsKey);
        if (raw != null && raw.isNotEmpty) {
          data = (jsonDecode(raw) as Map).cast<String, dynamic>();
        }
      } catch (e) {
        debugPrint('local load settings failed: $e');
      }
    }

    if (data == null || !mounted) return;
    setState(() => _applySettingsMap(data!));
  }

  Future<void> _saveJobSettings() async {
    final data = _currentSettingsMap();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, jsonEncode(data));

      // One-time cleanup of the legacy global key from the
      // pre-per-video implementation. Reads as a no-op after the
      // first save; harmless to run on every save.
      if (prefs.containsKey('job_settings_defaults_v1')) {
        await prefs.remove('job_settings_defaults_v1');
        debugPrint('Removed legacy global settings key');
      }
    } catch (e) {
      debugPrint('local save settings failed: $e');
    }

    _scheduleSettingsPush();
  }

  void _scheduleSettingsPush() {
    _settingsPushDebounce?.cancel();
    _settingsPushDebounce = Timer(
      const Duration(milliseconds: 800),
      _pushSettingsToServer,
    );
  }

  Future<void> _pushSettingsToServer() async {
    try {
      final resp = await http
          .put(
            Uri.parse(
                '$flaskServerUrl/video-job-settings/${widget.videoKey}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(_currentSettingsMap()),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('push settings: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('push settings failed: $e');
    }
  }

  /// Update a setting and persist the whole Job Settings block.
  void _updateSetting(VoidCallback change) {
    setState(change);
    _saveJobSettings();
  }  

  @override
  void dispose() {
    _autoCheckTimer?.cancel();
    _saveJobSettings();
    _settingsPushDebounce?.cancel();
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    _sessionNameController.dispose();
    _topicNameController.dispose();
    _speakerNameController.dispose();
    _shortenController.dispose();
    _muteController.dispose();
    _pauseController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// Base session name for a project that has no saved settings yet.
  ///
  /// Returns just the video's display name — the timestamp is appended
  /// at submit time by `_stampSessionNameForSubmit`, so the value the
  /// user sees while editing stays stable and the value KIT receives
  /// always carries the moment of submission.
  String _getDefaultSessionName() {
    return _detail?.name ?? 'Video';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SESSION DETAIL LOADING
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _fetchDetail() async {
    setState(() {
      _isLoadingDetail = true;
      _detailError = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token') ?? '';
      final response = await http.get(
        Uri.parse('$authBaseUrl/video-detail/${widget.videoKey}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final detail = SessionDetail.fromJson(data);
        if (!mounted) return;
        setState(() {
          _detail = detail;
          _isLoadingDetail = false;
          // Populate the session name controller once detail is available
          if (_sessionNameController.text.isEmpty) {
            _sessionNameController.text = _getDefaultSessionName();
          }
          // Topic always starts as the video key. Submit-time stamping keeps
          // them consistent on subsequent runs.
          if (_topicNameController.text.isEmpty) {
            _topicNameController.text = widget.videoKey;
          }
        });
        // Start the video now that we know the detail object.
        _initializeVideoPlayer(detail);
      } else {
        throw Exception('Failed to load detail (HTTP ${response.statusCode})');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detailError = e.toString();
        _isLoadingDetail = false;
      });
    }
  }

  Future<void> _refresh() async {
    await _fetchDetail();
    await _loadJobHistory();
    await _loadSavedSessionId();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  VIDEO PLAYER
  // ═══════════════════════════════════════════════════════════════════

  void _initializeVideoPlayer(SessionDetail detail) {
    // Tear down any previous controller (e.g. after a refresh).
    final old = _videoController;
    if (old != null) {
      old.removeListener(_onVideoProgress);
      old.dispose();
      _videoController = null;
    }
    _isVideoReady = false;

    // Prefer the explicit videoUrl from the backend; fall back to the
    // same media endpoint the upload path uses.
    final rawUrl = (detail.videoUrl != null && detail.videoUrl!.isNotEmpty)
        ? detail.videoUrl!
        : '$authBaseUrl/media/${widget.videoKey}';
    final url = rawUrl.startsWith('http') ? rawUrl : '$authBaseUrl$rawUrl';

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url))
      ..initialize().then((_) {
          if (!mounted) {
            _videoController?.dispose();
            _videoController = null;
            return;
          }
          setState(() => _isVideoReady = true);
          _videoController!.addListener(_onVideoProgress);
        }).catchError((error) {
          if (!mounted) return;
          setState(() {
            _detailError = 'Failed to load video: $error';
          });
        });
  }

  void _onVideoProgress() {
    if (!mounted) return;
    setState(() {});
  }

  void _togglePlayPause() {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    setState(() {});
  }

  void _seekTo(double seconds) {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    c.seekTo(Duration(milliseconds: (seconds * 1000).toInt()));
  }

  /// Open the current video in a fullscreen dialog.
  ///
  /// The inline player is paused while the dialog is open — otherwise
  /// two audio tracks play simultaneously and the user hears an echo.
  /// Keyboard shortcuts inside the dialog:
  ///   Esc            exit
  ///   Space          play / pause
  ///   ← / →          seek ±5 s
  Future<void> _openFullscreenVideo() async {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;

    final wasPlaying = c.value.isPlaying;
    if (wasPlaying) await c.pause();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      useSafeArea: false,
      builder: (_) => _FullscreenVideoDialog(controller: c),
    );

    if (mounted && wasPlaying) {
      await c.play();
    }
  }  

  Future<void> _loadSavedSessionId() async {
    final stored = await InternalAuthService.getSessionId(widget.videoKey);

    String resolvedId = (stored ?? '').trim();
    String resolvedUrl = '';

    if (resolvedId.isEmpty && _jobHistory.isNotEmpty) {
      final newest = _jobHistory.first;
      resolvedId = (newest['session_id'] as String? ?? '').trim();
      resolvedUrl = newest['session_url'] as String? ?? '';
    }

    if (!mounted || resolvedId.isEmpty) return;

    setState(() {
      _savedSessionId = resolvedId;
      _savedSessionUrl = resolvedUrl;
      _hasSessionId = true;

      final idx =
          _jobHistory.indexWhere((j) => j['session_id'] == resolvedId);
      final hasOut =
          idx != -1 && (_jobHistory[idx]['has_output'] as bool? ?? false);
      final files =
          idx != -1 ? (_jobHistory[idx]['output_files'] as int? ?? 0) : 0;

      _outputStatus = hasOut
          ? '✅ Output ready ($files files).'
          : '✅ Session ID loaded: $resolvedId\n'
              'Click "Check Output" to see results.';
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  JOB HISTORY
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _loadJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      // If this browser still has an old local copy from the previous
      // SharedPreferences implementation, push it to the server once.
      await _migrateLocalJobHistoryIfNeeded();

      final url = Uri.parse(
          '$flaskServerUrl/video-job-history/${widget.videoKey}');
      final response =
          await http.get(url).timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> raw = jsonDecode(response.body);
        setState(() {
          _jobHistory = raw
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          _jobHistory.sort((a, b) =>
              (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));
        });
        // backfill display fields on legacy entries
        await _backfillJobHistoryFields();
      } else if (response.statusCode == 404) {
        setState(() => _jobHistory = []);
      } else {
        debugPrint('loadJobHistory: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error loading job history: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  /// Fill in / refresh derived fields on every job-history entry.
  ///
  /// `pipeline` is treated as *derived*, not stored: it is recomputed
  /// from `pipeline_url` and the current `internalServerLabels` map on
  /// every load. That's what lets a change in `constants.dart` (e.g.
  /// dropping "(Default for now)" from a label) propagate to entries
  /// that were saved long before the change.
  ///
  /// Everything else here (email, remarks, audio_languages) is written
  /// only when missing, because those fields record facts about the
  /// job that the user may have customised — they are not derivable
  /// from the current state.
  Future<void> _backfillJobHistoryFields() async {
    final currentEmail = await _tokenEmail();
    var changed = false;

    for (final job in _jobHistory) {
      // ── pipeline_url ─────────────────────────────────────────────
      // Resolve the URL first: it's the input to the label lookup.
      // Legacy entries without a URL fall back to the current server.
      final rawUrl = (job['pipeline_url'] ?? '').toString().trim();
      final resolvedUrl =
          rawUrl.isEmpty ? internalServerUrl : rawUrl;
      if (rawUrl.isEmpty) {
        job['pipeline_url'] = resolvedUrl;
        changed = true;
      }

      // ── pipeline (label) ────────────────────────────────────────
      // Always recomputed. If the label map in constants.dart changes,
      // this entry picks up the new text on the very next load.
      final desiredLabel =
          internalServerLabels[resolvedUrl] ?? resolvedUrl;
      if (job['pipeline'] != desiredLabel) {
        job['pipeline'] = desiredLabel;
        changed = true;
      }

      // ── remarks ─────────────────────────────────────────────────
      if (job['remarks'] == null) {
        job['remarks'] = '';
        changed = true;
      }

      // ── audio_languages (TTS) ──────────────────────────────────
      if (job['audio_languages'] == null) {
        job['audio_languages'] = _audioLanguages.join(',');
        changed = true;
      }

      // ── email ───────────────────────────────────────────────────
      // Only filled in; never overwritten once set, because the
      // email records who actually ran the job at submission time.
      final existing = (job['email'] ?? '').toString().trim();
      if (existing.isEmpty && currentEmail.isNotEmpty) {
        job['email'] = currentEmail;
        changed = true;
      } else if (job['email'] == null) {
        job['email'] = '';
        changed = true;
      }
    }

    if (changed) {
      if (mounted) setState(() {});
      await _saveJobHistoryToServer();
    }
  }

  /// One-time migration: if this browser has job history in
  /// SharedPreferences from the previous (client-only) implementation,
  /// and the server doesn't yet have any for this video, push the local
  /// copy to the server and clear it locally.
  ///
  /// Safe to call on every load: it no-ops when there's nothing to do.
  Future<void> _migrateLocalJobHistoryIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      final local = prefs.getString(key);
      if (local == null || local.isEmpty) return;

      final url = Uri.parse(
          '$flaskServerUrl/video-job-history/${widget.videoKey}');

      // Probe the server first — if it already has data, the local
      // copy is stale and we drop it.
      final probe = await http.get(url).timeout(const Duration(seconds: 10));
      if (probe.statusCode != 200) return;

      final List<dynamic> serverList = jsonDecode(probe.body);
      if (serverList.isNotEmpty) {
        await prefs.remove(key);
        return;
      }

      // Server is empty and local has data: migrate.
      final List<dynamic> localList = jsonDecode(local);
      if (localList.isEmpty) {
        await prefs.remove(key);
        return;
      }

      final putResp = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(localList),
          )
          .timeout(const Duration(seconds: 10));

      if (putResp.statusCode == 200) {
        await prefs.remove(key);
        debugPrint(
              'Migrated ${localList.length} local job-history entries to server');
      }
    } catch (e) {
      debugPrint('Job-history migration skipped: $e');
    }
  }

  Future<void> _saveJobToHistory({
    required String sessionId,
    required String sessionUrl,
    required String sessionName,
    required String status,
    required bool hasOutput,
    int outputFiles = 0,
    String remarks = '',
  }) async {
    // Resolve the pipeline label + token email once.
    final pipelineLabel =
        internalServerLabels[internalServerUrl] ?? internalServerUrl;
    final emailUsed = await _tokenEmail();

    final existingIndex = _jobHistory
        .indexWhere((job) => job['session_id'] == sessionId);

    if (existingIndex != -1) {
      _jobHistory[existingIndex]['status'] = status;
      _jobHistory[existingIndex]['has_output'] = hasOutput;
      if (outputFiles > 0) {
        _jobHistory[existingIndex]['output_files'] = outputFiles;
      }
      _jobHistory[existingIndex]['pipeline'] = pipelineLabel;
      _jobHistory[existingIndex]['pipeline_url'] = internalServerUrl;
      _jobHistory[existingIndex]['email'] = emailUsed;
      if (remarks.isNotEmpty) {
        _jobHistory[existingIndex]['remarks'] = remarks;
      }
    } else {
      final jobEntry = {
        'session_id': sessionId,
        'session_url': sessionUrl,
        'session_name': sessionName,
        'timestamp': DateTime.now().toIso8601String(),
        'date': _date,
        'status': status,
        'has_output': hasOutput,
        'output_files': outputFiles,
        'input_languages': _inputLanguages.join(','),
        'output_languages': _outputLanguages.join(','),
        'audio_languages': _audioLanguages.join(','), 
        'availability': _availability,
        'pipeline': pipelineLabel,
        'pipeline_url': internalServerUrl,
        'email': emailUsed,
        'remarks': remarks,
      };
      _jobHistory.insert(0, jobEntry);
    }

    if (_jobHistory.length > 20) {
      _jobHistory = _jobHistory.sublist(0, 20);
    }

    if (mounted) setState(() {});
    await _saveJobHistoryToServer();
  }

  Future<void> _saveJobHistoryToServer() async {
    try {
      final url = Uri.parse(
          '$flaskServerUrl/video-job-history/${widget.videoKey}');
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(_jobHistory),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint(
            'saveJobHistory: HTTP ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Error saving job history: $e');
    }
  }

  /// Edit the free-text remarks on one job-history entry.
  ///
  /// Saves straight to the backend via /video-job-remarks so the note
  /// survives a page reload and is shared with every browser that
  /// opens this video.
  Future<void> _editJobRemarks(String sessionId) async {
    final index = _jobHistory
        .indexWhere((job) => job['session_id'] == sessionId);
    if (index == -1) return;

    final existing = (_jobHistory[index]['remarks'] ?? '').toString();
    final controller = TextEditingController(text: existing);

    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.edit_note, color: Colors.brown),
            SizedBox(width: 8),
            Text('Edit remarks'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Job: ${_jobHistory[index]['session_name'] ?? sessionId}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 6,
                minLines: 3,
                maxLength: 4096,
                decoration: const InputDecoration(
                  hintText:
                      'Notes about this run — quality, speaker notes, '
                      'which sections to revisit…',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (existing.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Clear'),
            ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, controller.text),
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.brown,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    controller.dispose();
    if (saved == null) return;

    // Optimistic local update so the list reflects the change
    // immediately, then persist. If the server rejects it we roll
    // back and show the error.
    final previous = _jobHistory[index]['remarks'];
    setState(() => _jobHistory[index]['remarks'] = saved);

    try {
      final url = Uri.parse(
        '$flaskServerUrl/video-job-remarks/'
        '${widget.videoKey}/${Uri.encodeComponent(sessionId)}',
      );
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'remarks': saved}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Remarks saved'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _jobHistory[index]['remarks'] = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save remarks: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteJobFromHistory(String sessionId) async {
    _jobHistory.removeWhere((job) => job['session_id'] == sessionId);
    if (mounted) setState(() {});
    await _saveJobHistoryToServer();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job removed from history')),
      );
    }
  }

  Future<void> _clearAllHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History?'),
        content: Text(
            'This will remove all ${_jobHistory.length} jobs for this video.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final url = Uri.parse(
            '$flaskServerUrl/video-job-history/${widget.videoKey}');
        final response =
            await http.delete(url).timeout(const Duration(seconds: 10));
        if (!mounted) return;

        if (response.statusCode == 200) {
          setState(() => _jobHistory.clear());
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('History cleared')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Failed to clear history: HTTP ${response.statusCode}'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error clearing history: $e')),
          );
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  CONNECTION / TOKEN
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _checkConnection() async {
    final token = await InternalAuthService.getToken();
    if (mounted) {
      setState(() => _isConnected = token != null && token.isNotEmpty);
    }
  }

  Future<void> _changeServer(String url) async {
    if (url == internalServerUrl) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch internal server?'),
        content: Text(
          'Switch to:\n$url\n\n'
          'Tokens and sessions you created on the previous server may no '
          'longer work. You will likely need to reconnect and paste a new '
          'token.',
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

    // Tokens are per-server. The old one is worthless here — drop it so
    // the user is forced to fetch a new one for the new host.
    await InternalAuthService.clearManualToken();

    setState(() {
      _isConnected = false;
      _isCancelling = false;
      _hasSessionId = false;
      _savedSessionId = '';
      _savedSessionUrl = '';
      _outputStatus = '';
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
      if (success && mounted) {
        setState(() => _isConnected = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Connected to internal server!')),
        );
        await _checkConnection();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Connection failed. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
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
      if (mounted) {
        setState(() {
          _isConnected = true;
          _tokenStatus = '✅ Token set successfully!';
          _showTokenInput = false;
          _tokenController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Token set manually!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tokenStatus = '❌ Error: $e');
      }
    }
  }

  Future<void> _clearManualToken() async {
    try {
      await InternalAuthService.clearManualToken();
      if (mounted) {
        setState(() {
          _isConnected = false;
          _tokenStatus = 'Token cleared';
          _tokenController.clear();
          _showTokenInput = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Manual token cleared.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tokenStatus = '❌ Error: $e');
      }
    }
  }

  void _openTokenPage() {
    final url = '$internalServerUrl/gettoken';
    html.window.open(url, 'gettoken_tab');
    setState(() {
      _tokenStatus =
          '📋 Copy the token from the new tab, then click "Paste Token"';
    });
  }

  String? _extractToken(String raw) {
    if (raw.isEmpty) return null;

    final preMatch = RegExp(
      r'<pre>\s*([^<]+?)\s*</pre>',
      multiLine: true,
    ).firstMatch(raw);
    if (preMatch != null) {
      final t = preMatch.group(1)?.trim();
      if (t != null && t.isNotEmpty) return t;
    }

    final cookieMatch =
        RegExp(r"([^\s'<>|]+\|\d{10}\|[^\s'<>]+)").firstMatch(raw);
    if (cookieMatch != null) {
      return cookieMatch.group(1)?.trim();
    }

    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : null;
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final text = await html.window.navigator.clipboard?.readText();
      if (text == null || text.isEmpty) {
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
    html.window.navigator.clipboard?.writeText(_bookmarkletJs);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Bookmarklet copied. Create a new bookmark and paste this as its URL.',
        ),
      ),
    );
  }

  Future<String> _getToken() async {
    final token = await InternalAuthService.getToken();
    return token ?? '';   // don't throw; caller decides
  }

  // ═══════════════════════════════════════════════════════════════════
  //  OUTPUT CHECKING
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _checkOutput() async {
    if (_savedSessionId.isEmpty) {
      if (mounted) {
        setState(() {
          _outputStatus =
              '❌ No session ID available. Please upload a video first.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isCheckingOutput = true;
        _outputStatus = '🔄 Checking for output files...';
      });
    }

    try {
      final token = await InternalAuthService.getToken() ?? '';
      final url = '$flaskServerUrl/session-output/$_savedSessionId';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        if (totalFiles > 0) {
          final jobIndex = _jobHistory
              .indexWhere((job) => job['session_id'] == _savedSessionId);

          setState(() {
            if (jobIndex != -1) {
              _jobHistory[jobIndex]['has_output'] = true;
              _jobHistory[jobIndex]['status'] = 'Completed ✅';
              _jobHistory[jobIndex]['output_files'] = totalFiles;
            } else {
              // Entry missing — create it.
              _jobHistory.insert(0, {
                'session_id': _savedSessionId,
                'session_url': _savedSessionUrl,
                'session_name': _sessionNameController.text.trim(),
                'timestamp': DateTime.now().toIso8601String(),
                'date': _date,
                'status': 'Completed ✅',
                'has_output': true,
                'output_files': totalFiles,
                'input_languages': _inputLanguages.join(','),
                'output_languages': _outputLanguages.join(','),
                'availability': _availability,
              });
            }
            _isCheckingOutput = false;
            _outputStatus = '✅ Output is ready! Found $totalFiles files.';
          });
          await _saveJobHistoryToServer();

          if (mounted) {
            setState(() {
              _isCheckingOutput = false;
              _outputStatus = '✅ Output is ready! Found $totalFiles files.';
            });

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Output ready! $totalFiles files available.'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          if (mounted) {
            setState(() {
              _isCheckingOutput = false;
              _outputStatus = '⏳ Still processing... No output files found yet.\n'
                  'Please wait a few more minutes and try again.';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _isCheckingOutput = false;
            _outputStatus = '❌ Failed to check output: ${response.statusCode}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingOutput = false;
          _outputStatus = '❌ Error checking output: $e';
        });
      }
    }
  }

    Future<void> _cancelJob() async {
    if (_savedSessionId.isEmpty || _isCancelling) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel processing?'),
        content: const Text(
          'The background worker will stop within a few seconds. Files '
          'already downloaded stay on the server, but no further '
          'translations will be fetched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep running'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel processing'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isCancelling = true);
    try {
      final token = await _getToken();
      final url = '$flaskServerUrl/cancel_session/$_savedSessionId';
      final response = await http.post(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final idx = _jobHistory
            .indexWhere((j) => j['session_id'] == _savedSessionId);
        if (idx != -1) {
          _jobHistory[idx]['status'] = 'Cancelled 🛑';
          _jobHistory[idx]['has_output'] = false;
          await _saveJobHistoryToServer();
        }

        setState(() {
          _outputStatus =
              '🛑 Cancel requested — the worker will stop shortly.';
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cancel requested'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        setState(() {
          _outputStatus = '❌ Cancel failed: HTTP ${response.statusCode}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _outputStatus = '❌ Cancel error: $e');
      }
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  Future<void> _checkHistoricalOutput(String sessionId) async {
    if (sessionId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ No session ID for this job')),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔄 Checking output status...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      // Do NOT require a token. The Flask backend serves whatever files
      // it already has on disk; the token is only needed for it to fetch
      // anything *missing* from the KIT server. If the user is offline,
      // they still get the local status — which is what they asked for.
      final token = await InternalAuthService.getToken() ?? '';

      final url = '$flaskServerUrl/session-output/$sessionId';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final totalFiles = (data['total_files'] as num?)?.toInt() ?? 0;
        final backendStatus = data['status'] as String? ?? 'processing';

        final jobIndex =
            _jobHistory.indexWhere((job) => job['session_id'] == sessionId);
        if (jobIndex == -1) return;

        if (totalFiles > 0) {
          setState(() {
            _jobHistory[jobIndex]['has_output'] = true;
            _jobHistory[jobIndex]['status'] = 'Completed ✅';
            _jobHistory[jobIndex]['output_files'] = totalFiles;
          });
          await _saveJobHistoryToServer();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Output ready! Found $totalFiles files.'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 3),
              ),
            );
            setState(() {});
          }
        } else {
          // No files on disk yet. Two sub-cases:
          //  • still processing on the KIT server → tell them to wait;
          //  • offline and nothing downloaded yet → tell them to connect.
          final String msg;
          if (token.isEmpty) {
            msg = '🔌 Not connected — no files downloaded locally yet.\n'
                'Connect to the internal server to fetch the output.';
          } else if (backendStatus == 'ready') {
            msg = '✅ Session processed, but no files are on disk yet.\n'
                'Try "Check Status" again in a moment.';
          } else {
            msg = '⏳ Still processing... No output files found yet.';
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(msg),
                duration: const Duration(seconds: 4),
                backgroundColor: token.isEmpty ? Colors.orange : null,
              ),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Failed to check output: HTTP ${response.statusCode}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error checking output: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _viewHistoricalOutput(String sessionId, String sessionUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionOutputScreen(
          sessionId: sessionId,
          sessionUrl: sessionUrl.isNotEmpty
              ? sessionUrl
              : '$internalServerUrl/archivesession/$sessionId',
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LANGUAGE TOGGLES
  // ═══════════════════════════════════════════════════════════════════

  void _toggleInputLanguage(String lang) {
    _updateSetting(() {
      if (_inputLanguages.contains(lang)) {
        _inputLanguages.remove(lang);
      } else {
        _inputLanguages.add(lang);
      }
    });
  }

  void _toggleOutputLanguage(String lang) {
    _updateSetting(() {
      if (_outputLanguages.contains(lang)) {
        _outputLanguages.remove(lang);
      } else {
        _outputLanguages.add(lang);
      }
    });
  }

  void _toggleAudioLanguage(String lang) {
    _updateSetting(() {
      if (_audioLanguages.contains(lang)) {
        _audioLanguages.remove(lang);
      } else {
        _audioLanguages.add(lang);
      }
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SAVED SETTINGS DIALOGS
  // ═══════════════════════════════════════════════════════════════════

  /// Show the settings file that lives on the backend for this video,
  /// plus buttons to reload it into the form or delete it.
  Future<void> _showSavedSettingsDialog() async {
    Map<String, dynamic>? remote;

    try {
      final resp = await http
          .get(Uri.parse(
              '$flaskServerUrl/video-job-settings/${widget.videoKey}'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map) {
          remote = parsed.cast<String, dynamic>();
        }
      }
    } catch (e) {
      debugPrint('view saved settings failed: $e');
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final has = remote != null && remote.isNotEmpty;
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.save_outlined, color: Colors.blue),
              SizedBox(width: 8),
              Text('Saved settings'),
            ],
          ),
          content: SizedBox(
            width: 640,
            height: 480,
            child: has
                ? Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(remote),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  )
                : const Center(
                    child: Text(
                      'No settings have been saved for this video yet.\n'
                      'Change something above and they will be persisted '
                      'automatically.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
          ),
          actions: [
            if (has)
              TextButton.icon(
                onPressed: () async {
                  try {
                    await http.delete(Uri.parse(
                        '$flaskServerUrl/video-job-settings/${widget.videoKey}'));
                  } catch (_) {}
                  if (!mounted) return;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Saved settings cleared')),
                  );
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete file'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            if (has)
              ElevatedButton.icon(
                onPressed: () {
                  setState(() => _applySettingsMap(remote!));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Settings reloaded')),
                  );
                },
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Reload into form'),
              ),
          ],
        );
      },
    );
  }

  /// Ask for a name and POST the current settings as a named preset.
  Future<void> _saveCurrentAsPreset() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bookmark_add_outlined, color: Colors.blue),
            SizedBox(width: 8),
            Text('Save as preset'),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Preset name',
              hintText: 'e.g. "English lecture – default"',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty) return;
              Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    try {
      final resp = await http.post(
        Uri.parse('$flaskServerUrl/job-settings-presets'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'settings': _currentSettingsMap(),
        }),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Preset "$name" saved')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: HTTP ${resp.statusCode}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// List all presets on the server; tap one to load it into the form.
  Future<void> _loadPresetDialog() async {
    Map<String, dynamic> presets = {};

    try {
      final resp = await http
          .get(Uri.parse('$flaskServerUrl/job-settings-presets'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = body['presets'];
        if (raw is Map) {
          presets = raw.cast<String, dynamic>();
        }
      }
    } catch (e) {
      debugPrint('load presets failed: $e');
    }

    if (!mounted) return;

    await showDialog<void>(
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
          width: 520,
          height: 400,
          child: presets.isEmpty
              ? const Center(
                  child: Text(
                    'No presets saved yet.\nUse "Save as preset" first.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.separated(
                  itemCount: presets.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final name = presets.keys.elementAt(i);
                    final settings = presets[name];
                    final savedAt =
                        (settings is Map ? settings['saved_at'] : null) ?? '';
                    return ListTile(
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(name),
                      subtitle: savedAt.toString().isEmpty
                          ? null
                          : Text(
                              'saved $savedAt',
                              style: const TextStyle(fontSize: 11),
                            ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.red),
                        tooltip: 'Delete preset',
                        onPressed: () async {
                          try {
                            await http.delete(Uri.parse(
                              '$flaskServerUrl/job-settings-presets'
                              '?name=${Uri.encodeComponent(name)}',
                            ));
                          } catch (_) {}
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                      onTap: () {
                        if (settings is Map) {
                          setState(() => _applySettingsMap(
                              settings.cast<String, dynamic>()));
                          _saveJobSettings();
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Loaded preset "$name"')),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SUBMIT
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _submitJob() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();
      
    // Stamp the current date/time into the session name and set the
    // topic to the video key, before the form values are read below.
    // A user-supplied name is preserved because the controllers are
    // only overwritten here, at submit time — never on load.
    _stampSessionNameForSubmit();

    if (_inputLanguages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please pick at least one input language.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_outputLanguages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please pick at least one output language.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final token = await _getToken();
      debugPrint('🚀 [UPLOAD] Using token: $token');

      await _uploadToInternalServer(
        token: token,
        sessionName: _sessionNameController.text.trim(),
        topicName: _topicNameController.text.trim(),
        date: _date,
        speakerName: _speakerNameController.text.trim(),
        availability: _availability,
        inputLanguages: _inputLanguages,
        outputLanguages: _outputLanguages,
        audioLanguages: _audioLanguages,
        profanityFilter: _profanityFilter,
        filterMusic: _filterMusic,
        enableSummarization: _enableSummarization,
        enableLiveNotes: _enableLiveNotes,
        enableDiarization: _enableDiarization,
        enableAIAssistant: _enableAIAssistant,
        saveSession: _saveSession,
        distinguishUnknownSpeakers: _distinguishUnknownSpeakers,
        smartChaptering: _smartChaptering,
        format: _format,
        ttsQualityMode: _ttsQualityMode,
        errorCorrection: _errorCorrection,
        postproduction: _postproduction,
        shorten: _shortenController.text.trim(),
        mute: int.tryParse(_muteController.text.trim()) ?? 120,
        pause: double.tryParse(_pauseController.text.trim()) ?? 2.0,
      );
    } catch (e) {
      debugPrint('❌ [DEBUG] Exception caught: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }


  /// Stamp the current date/time onto the session name and set the
  /// topic to the video key, but only if the user has not overridden
  /// the default.
  ///
  /// "Overridden" is detected by comparing the field to the current
  /// default (`<video name>` with no timestamp) and to the previous
  /// default (`<video name> – <timestamp>`). Anything else is treated
  /// as user input and left alone.
  void _stampSessionNameForSubmit() {
    final current = _sessionNameController.text.trim();
    final videoName = _detail?.name ?? 'Video';
    final defaultPlain = videoName;
    final looksLikePreviousStamp =
        current == defaultPlain || current.startsWith('$videoName – ');

    if (looksLikePreviousStamp) {
      final now = DateTime.now();
      final dateTimeStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      _sessionNameController.text = '$videoName – $dateTimeStr';
    }

    // Topic always mirrors the key — it is a machine identifier, not
    // free text, and the user has no reason to edit it.
    _topicNameController.text = widget.videoKey;
  }

  Future<void> _uploadToInternalServer({
    required String token,
    required String sessionName,
    required String topicName,
    required String date,
    required String speakerName,
    required String availability,
    required List<String> inputLanguages,
    required List<String> outputLanguages,
    required List<String> audioLanguages,
    required bool profanityFilter,
    required bool filterMusic,
    required bool enableSummarization,
    required bool enableLiveNotes,
    required bool enableDiarization,
    required bool enableAIAssistant,
    required bool saveSession,
    required bool distinguishUnknownSpeakers,
    required String smartChaptering,
    required String format,
    required String ttsQualityMode,
    required String errorCorrection,
    required List<String> postproduction,
    required String shorten,
    required int mute,
    required double pause,
  }) async {
    final uploadUrl = '$flaskServerUrl/upload';

    // Compact JSON body. The 1 GB video never crosses the network —
    // the backend reads it from its own uploads/ folder using
    // `video_key`, builds the green-screen, and sends only that
    // small file to KIT.
    final body = <String, dynamic>{
      'video_key': widget.videoKey,
      'token': token,
      'targetServer': internalServerUrl,
      'name': sessionName,
      'topicname': topicName,
      'date': date,
      'speakername': speakerName,
      'availability': availability,
      'format': format,
      'smartChaptering': smartChaptering,
      'errorCorrection': errorCorrection,
      'ttsQualityMode': ttsQualityMode,
      'language': inputLanguages,
      'mtLanguage': outputLanguages,
      'audioLanguage': audioLanguages,
      'profanity': profanityFilter ? '1' : '0',
      'filter_music': filterMusic ? '1' : '0',
      'summarization': enableSummarization ? '1' : '0',
      'notes': enableLiveNotes ? '1' : '0',
      'saasr': enableDiarization ? '1' : '0',
      'aiassistant': enableAIAssistant ? '1' : '0',
      'logging': saveSession ? '1' : '0',
      'distinguish_unknown_speakers':
          distinguishUnknownSpeakers ? '1' : '0',
      'postproduction': postproduction,
      'shorten': shorten,
      'mute': mute.toString(),
      'pause': pause.toString(),
      'legals': '1',
      'profile': 'profile_1',
      'profile_names': '',
      'save_profile': '1',
    };

    final encoded = jsonEncode(body);
    debugPrint(
      '📤 [UPLOAD] POST $uploadUrl  '
      '(body=${encoded.length} bytes, video_key=${widget.videoKey})',
    );

    final response = await http.post(
      Uri.parse(uploadUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: encoded,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Upload failed: HTTP ${response.statusCode} — ${response.body}',
      );
    }

    // The backend always returns JSON. Parse it.
    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(
        'Server returned a non-JSON response: ${response.body}',
      );
    }

    final sessionId = data['session_id']?.toString() ?? '';
    final sessionUrl = data['session_url']?.toString() ?? '';

    if (sessionId.isEmpty) {
      throw Exception(
        'Server did not return a session_id. Body: ${response.body}',
      );
    }

    if (!mounted) return;

    // KIT can put a raw_response / message inside a "data" object,
    // or as a top-level "message". Try all three.
    String pickMessage() {
      final d = data['data'];
      if (d is Map) {
        final m = d['raw_response'] ?? d['message'];
        if (m != null) return m.toString();
      }
      final top = data['message'];
      if (top != null) return top.toString();
      return 'Upload successful!';
    }

    setState(() {
      _responseMessage = pickMessage();
      _responseHtml = data['html']?.toString() ?? '';
      _sessionUrl = sessionUrl;
      _sessionId = sessionId;
      _videoKeyResponse = data['video_key']?.toString() ?? '';
      _showResponse = true;

      _savedSessionId = sessionId;
      _savedSessionUrl = sessionUrl;
      _hasSessionId = true;
      _outputStatus =
          '✅ Upload complete! Session ID: $sessionId\n'
          'Click "Check Output" to see if processing is finished.';
    });

    await InternalAuthService.saveSessionId(widget.videoKey, sessionId);
    await _saveJobToHistory(
      sessionId: sessionId,
      sessionUrl: sessionUrl,
      sessionName: sessionName,
      status: 'Processing... ⏳',
      hasOutput: false,
    );

    _printSessionLink();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Upload complete! Session ID: $sessionId'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // ignore: unused_element
  String? _parseHtmlResponseAndReturnSessionId(String html) {
    final RegExp linkRegex = RegExp(r'<a href="([^"]+)"[^>]*>([^<]+)</a>');
    final linkMatch = linkRegex.firstMatch(html);
    if (linkMatch != null) {
      final url = linkMatch.group(1) ?? '';
      if (url.isNotEmpty) {
        String cleanUrl = url.replaceAll(RegExp(r'\s+'), '');
        cleanUrl = cleanUrl.replaceAll('ist.iar', 'isl.iar');
        _sessionUrl = cleanUrl;

        if (cleanUrl.contains('/archivesession/')) {
          final sessionId =
              cleanUrl.split('/archivesession/')[-1].split('/')[0];
          final cleanedId =
              sessionId.replaceAll(RegExp(r'\s+'), '').split('"')[0];
          if (cleanedId.isNotEmpty) {
            _sessionId = cleanedId;
            return cleanedId;
          }
        }
      }
    }

    final RegExp videoKeyRegex =
        RegExp(r'<strong>Video Key:</strong>\s*([^<]+)');
    final videoMatch = videoKeyRegex.firstMatch(html);
    if (videoMatch != null && videoMatch.groupCount >= 1) {
      _videoKeyResponse = videoMatch.group(1)?.trim() ?? '';
    }

    if (_sessionId.isEmpty) {
      final RegExp sessionIdRegex =
          RegExp(r'<strong>Session ID:</strong>\s*([^<]+)');
      final sessionMatch = sessionIdRegex.firstMatch(html);
      if (sessionMatch != null && sessionMatch.groupCount >= 1) {
        _sessionId = sessionMatch.group(1)?.trim() ?? '';
        if (_sessionId.isNotEmpty) {
          return _sessionId;
        }
      }
    }

    return null;
  }

  void _printSessionLink() {
    if (_sessionUrl.isNotEmpty) {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('📎 SESSION LINK:');
      debugPrint(_sessionUrl);
      debugPrint('═══════════════════════════════════════════════════════════');
    }
    if (_sessionId.isNotEmpty) {
      debugPrint('🆔 SESSION ID: $_sessionId');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  FORMATTING HELPERS
  // ═══════════════════════════════════════════════════════════════════

  String _formatDuration(double seconds) {
    final int totalSec = seconds.round();
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      return '$bytes B';
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  GREEN VIDEO INFO PANEL
  // ═══════════════════════════════════════════════════════════════════

  /// Full date + exact time, e.g. `2025-06-14 15:32:08`.
  String _formatDateTimeExact(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  /// One labelled cell inside a green panel section.
  Widget _greenInfoCell({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final narrow = _isNarrow(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.green.shade700),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: narrow ? 11 : 12,
                  color: Colors.green.shade800,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: narrow ? 13 : 14,
              fontWeight: FontWeight.bold,
              color: Colors.green.shade900,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  /// A row of up to three cells, stacked vertically on narrow screens.
  Widget _greenInfoRow({
    required bool narrow,
    required List<Widget> cells,
  }) {
    if (narrow) {
      final widgets = <Widget>[];
      for (int i = 0; i < cells.length; i++) {
        if (i > 0) widgets.add(const SizedBox(height: 10));
        widgets.add(cells[i]);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      );
    }

    final expanded = <Widget>[];
    for (int i = 0; i < cells.length; i++) {
      if (i > 0) {
        expanded.add(VerticalDivider(
          width: 1,
          thickness: 1,
          color: Colors.green.shade200,
        ));
      }
      expanded.add(Expanded(child: cells[i]));
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: expanded,
      ),
    );
  }

  /// Small all-caps subheading inside the green panel.
  Widget _greenSectionLabel(String text, bool narrow) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: narrow ? 10 : 11,
        fontWeight: FontWeight.w700,
        color: Colors.green.shade700,
        letterSpacing: 0.8,
      ),
    );
  }


  /// Green panel under the video player: original file stats, the
  /// green-screen stand-in that the backend built for processing, and
  /// the available transcript languages.
  Widget _buildGreenVideoInfo(SessionDetail detail) {
    final narrow = _isNarrow(context);

    final hasGreenscreen = detail.greenscreenFileSize > 0 ||
        detail.greenscreenCreatedAt != null ||
        detail.greenscreenStatus == 'ready';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(narrow ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.shade300, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.movie_filter,
                  color: Colors.green.shade700, size: 20),
              const SizedBox(width: 8),
              Text(
                'Video Information',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade800,
                  fontSize: narrow ? 14 : 16,
                ),
              ),
            ],
          ),
          SizedBox(height: narrow ? 10 : 12),

          // ── Original section, row 1 ──────────────────────────────
          _greenSectionLabel('Original', narrow),
          const SizedBox(height: 6),
          _greenInfoRow(
            narrow: narrow,
            cells: [
              _greenInfoCell(
                icon: Icons.storage,
                label: 'File Size',
                value: _formatBytes(detail.fileSize),
              ),
              _greenInfoCell(
                icon: Icons.access_time,
                label: 'Uploaded At',
                value: _formatDateTimeExact(detail.uploaded),
              ),
              _greenInfoCell(
                icon: Icons.timer_outlined,
                label: 'Duration',
                value: _formatDuration(detail.duration),
              ),
            ],
          ),

          // ── Original section, row 2 ──────────────────────────────
          const SizedBox(height: 10),
          _greenInfoRow(
            narrow: narrow,
            cells: [
              _greenInfoCell(
                icon: Icons.speed,
                label: 'FPS',
                value: detail.fps.toStringAsFixed(1),
              ),
              _greenInfoCell(
                icon: Icons.layers,
                label: 'Segments',
                value: detail.segmentCount.toString(),
              ),
              _greenInfoCell(
                icon: Icons.history,
                label: 'Last Opened',
                value: detail.lastOpened != null
                    ? _formatDateTimeExact(detail.lastOpened!)
                    : '—',
              ),
            ],
          ),
                    // ── Languages section (only when non-empty) ──────────────
          if (detail.languages.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(color: Colors.green.shade200, height: 1),
            const SizedBox(height: 10),
            _greenSectionLabel('Languages', narrow),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: detail.languages
                  .map(
                    (lang) => Chip(
                      label: Text(
                        lang,
                        style: TextStyle(
                          fontSize: narrow ? 11 : 13,
                          color: Colors.green.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      backgroundColor: Colors.green.shade100,
                      side: BorderSide(color: Colors.green.shade300),
                      visualDensity: narrow
                          ? VisualDensity.compact
                          : VisualDensity.standard,
                    ),
                  )
                  .toList(),
            ),
          ],


          // ── Green-screen section (only when one exists) ──────────
          if (hasGreenscreen) ...[
            const SizedBox(height: 14),
            Divider(color: Colors.green.shade200, height: 1),
            const SizedBox(height: 10),
            _greenSectionLabel(
              'Green-screen (uploaded for processing)',
              narrow,
            ),
            const SizedBox(height: 6),
            _greenInfoRow(
              narrow: narrow,
              cells: [
                _greenInfoCell(
                  icon: Icons.storage,
                  label: 'File Size',
                  value: detail.greenscreenFileSize > 0
                      ? _formatBytes(detail.greenscreenFileSize)
                      : '—',
                ),
                _greenInfoCell(
                  icon: Icons.access_time,
                  label: 'Created At',
                  value: detail.greenscreenCreatedAt != null
                      ? _formatDateTimeExact(detail.greenscreenCreatedAt!)
                      : '—',
                ),
                _greenInfoCell(
                  icon: Icons.check_circle_outline,
                  label: 'Status',
                  value: detail.greenscreenStatus,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _stripHtmlTags(String html) {
    String text = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™')
        .replaceAll('&bull;', '•')
        .replaceAll('&hellip;', '…');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  String _extractVideoKey(String html) {
    final RegExp regex = RegExp(r'<strong>Video Key:</strong>\s*([^<]+)');
    final match = regex.firstMatch(html);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)?.trim() ?? '';
    }
    return '';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – DETAIL SECTION
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildDetailHeader() {
    if (_isLoadingDetail) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_detailError != null || _detail == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.orange),
            const SizedBox(height: 12),
            Text(
              _detailError ?? 'No data available',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _refresh,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final detail = _detail!;


    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── Video player (same size as session_output_screen) ─────
        Center(
          child: SizedBox(
            width: double.infinity,
            height: Responsive.of(context).videoHeight,
            child: Container(
              color: Colors.black,
              child: Stack(
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.9,
                        maxHeight: Responsive.of(context).videoHeight,
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _isVideoReady
                                ? VideoPlayerWidget(
                                    controller: _videoController,
                                    isReady: _isVideoReady,
                                    onPlayPause: _togglePlayPause,
                                    onSeek: _seekTo,
                                    height: Responsive.of(context).videoHeight,
                                  )
                                : const Center(
                                    child: CircularProgressIndicator(color: Colors.white),
                                  ),
                          ),
                          // ── Fullscreen toggle ─────────────────────────────────
                          if (_isVideoReady)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Material(
                                color: Colors.black54,
                                shape: const CircleBorder(),
                                child: IconButton(
                                  tooltip: 'Fullscreen',
                                  icon: const Icon(Icons.fullscreen, color: Colors.white),
                                  onPressed: _openFullscreenVideo,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),                ],
              ),
            ),
          ),
        ),
  
        const SizedBox(height: 16),

        // Title & file name
        Text(
          detail.name,
          style: TextStyle(
            fontSize: _titleSize(context),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail.fileName,
          style: TextStyle(
            color: Colors.grey,
            fontSize: _bodySize(context) - 1,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        const SizedBox(height: 16),
        // ─── Green video info panel (size / upload time / duration) ───
        _buildGreenVideoInfo(detail),

        // Segments (collapsible)
        if (detail.segments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: const Icon(Icons.movie, color: Colors.blue),
                title: Text(
                  'Segments (${detail.segments.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15),
                ),
                children: [
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: detail.segments.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, index) {
                      final seg = detail.segments[index];
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          child: Text('${index + 1}',
                              style: const TextStyle(fontSize: 11)),
                        ),
                        title: Text(
                          '${_formatDuration(seg.start)} – ${_formatDuration(seg.end)}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: seg.language != null
                            ? Text(seg.language!,
                                style: const TextStyle(fontSize: 11))
                            : null,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – JOB CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildDropdownField<T>({
    required String label,
    required T value,
    required List<T> options,
    required ValueChanged<T?> onChanged,
    String? Function(T?)? validator,
  }) {
    return FormField<T>(
      initialValue: value,
      validator: validator,
      builder: (field) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InputDecorator(
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
                errorText: field.errorText,
              ),
              child: DropdownButton<T>(
                value: field.value,
                isExpanded: true,
                underline: const SizedBox(),
                items: options.map((opt) {
                  return DropdownMenuItem<T>(
                    value: opt,
                    child: Text(opt.toString()),
                  );
                }).toList(),
                onChanged: (newVal) {
                  field.didChange(newVal);
                  onChanged(newVal);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMultiSelectChips({
    required String label,
    required List<String> selected,
    required List<String> allOptions,
    required ValueChanged<List<String>> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: allOptions.map((opt) {
            return FilterChip(
              label: Text(opt),
              selected: selected.contains(opt),
              onSelected: (isSelected) {
                if (isSelected) {
                  onChanged([...selected, opt]);
                } else {
                  onChanged(selected.where((e) => e != opt).toList());
                }
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _chipAction(
    BuildContext c, {
    required String label,
    required VoidCallback? onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: _isNarrow(c) ? 6 : 8),
        minimumSize: Size(0, _isNarrow(c) ? 28 : 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: TextStyle(fontSize: _isNarrow(c) ? 12 : 13),
      ),
      child: Text(label),
    );
  }

  Widget _buildLanguageBlock({
    required BuildContext context,
    required String title,
    required List<String> availableCodes,
    required List<String> selected,
    required String Function(String code) nameFor,
    required void Function(String code) onToggle,
    required void Function(List<String>) onReplaceAll,
  }) {
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
            // Compact action buttons; on narrow screens they shrink a bit
            // further so the title still has room to breathe.
            _chipAction(
              context,
              label: 'All',
              onPressed: selected.length == availableCodes.length
                  ? null
                  : () => onReplaceAll([...availableCodes]),
            ),
            const SizedBox(width: 2),
            _chipAction(
              context,
              label: 'None',
              onPressed: selected.isEmpty
                  ? null
                  : () => onReplaceAll(const []),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: _isNarrow(context) ? 6 : 8,
          runSpacing: 4,
          children: availableCodes.map((code) {
            final displayName = nameFor(code);
            return FilterChip(
              label: Text(
                '$displayName ($code)',
                style: TextStyle(fontSize: _isNarrow(context) ? 11 : 13),
              ),
              selected: selected.contains(code),
              onSelected: (_) => onToggle(code),
              visualDensity: _isNarrow(context)
                  ? VisualDensity.compact
                  : VisualDensity.standard,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSettingsPanel() {
    final inputLangCodes = LanguageConfig.getSortedInputLanguages();
    final outputLangCodes = LanguageConfig.getSortedOutputLanguages();
    final audioLangCodes = LanguageConfig.getSortedAudioLanguages();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Session Name
        TextFormField(
          controller: _sessionNameController,
          decoration: const InputDecoration(
            labelText: 'Session Name',
            border: OutlineInputBorder(),
          ),
          validator: (val) => val == null || val.trim().isEmpty
              ? 'Please enter a name'
              : null,
          onChanged: (_) {
            if (_topicNameController.text == _sessionNameController.text) {
              _topicNameController.text = _sessionNameController.text;
            }
          },
        ),
        const SizedBox(height: 16),

        // Topic, Date, Speaker
        TextFormField(
          controller: _topicNameController,
          decoration: const InputDecoration(
            labelText: 'Topic Name',
            border: OutlineInputBorder(),
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
            final reg = RegExp(r'^\d{4}-\d{2}-\d{2}$');
            if (!reg.hasMatch(val)) return 'Use YYYY-MM-DD format';
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
          context: context,
          title: 'Input Languages',
          availableCodes: inputLangCodes,
          selected: _inputLanguages,
          nameFor: LanguageConfig.getInputLanguageName,
          onToggle: _toggleInputLanguage,
          onReplaceAll: (newList) => _updateSetting(() {
            _inputLanguages
              ..clear()
              ..addAll(newList);
          }),
        ),
        const SizedBox(height: 16),

        _buildLanguageBlock(
          context: context,
          title: 'Output Languages (Translation)',
          availableCodes: outputLangCodes,
          selected: _outputLanguages,
          nameFor: LanguageConfig.getOutputLanguageName,
          onToggle: _toggleOutputLanguage,
          onReplaceAll: (newList) => _updateSetting(() {
            _outputLanguages
              ..clear()
              ..addAll(newList);
          }),
        ),
        const SizedBox(height: 16),

        _buildLanguageBlock(
          context: context,
          title: 'Generated Audio Languages',
          availableCodes: audioLangCodes,
          selected: _audioLanguages,
          nameFor: LanguageConfig.getAudioLanguageName,
          onToggle: _toggleAudioLanguage,
          onReplaceAll: (newList) => _updateSetting(() {
            _audioLanguages
              ..clear()
              ..addAll(newList);
          }),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Availability',
          value: _availability,
          options: _availabilityOptions,
          onChanged: (val) => _updateSetting(() => _availability = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Presentation Format',
          value: _format,
          options: _formatOptions,
          onChanged: (val) => _updateSetting(() => _format = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Smart Chaptering',
          value: _smartChaptering,
          options: _chapteringOptions,
          onChanged: (val) => _updateSetting(() => _smartChaptering = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'TTS Quality Mode',
          value: _ttsQualityMode,
          options: _ttsQualityOptions,
          onChanged: (val) => _updateSetting(() => _ttsQualityMode = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Error Correction',
          value: _errorCorrection,
          options: _errorCorrectionOptions,
          onChanged: (val) => _updateSetting(() => _errorCorrection = val!),
        ),
        const SizedBox(height: 16),

        _buildMultiSelectChips(
          label: 'Shortening (Post-production)',
          selected: _postproduction,
          allOptions: _postproductionOptions,
          onChanged: (newList) =>
              _updateSetting(() => _postproduction..clear()..addAll(newList)),
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
          Column(
            children: [
              TextFormField(
                controller: _muteController,
                decoration: const InputDecoration(
                  labelText: 'Notify timeout (minutes)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => _saveJobSettings(),
                validator: (val) {
                  if (val == null || val.isEmpty) return null;
                  if (int.tryParse(val) == null) return 'Enter a number';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pauseController,
                decoration: const InputDecoration(
                  labelText: 'Speech segment timeout (seconds)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => _saveJobSettings(),
                validator: (val) {
                  if (val == null || val.isEmpty) return null;
                  if (double.tryParse(val) == null) return 'Enter a number';
                  return null;
                },
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _muteController,
                  decoration: const InputDecoration(
                    labelText: 'Notify timeout (minutes)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _saveJobSettings(),
                  validator: (val) {
                    if (val == null || val.isEmpty) return null;
                    if (int.tryParse(val) == null) return 'Enter a number';
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _pauseController,
                  decoration: const InputDecoration(
                    labelText: 'Speech segment timeout (seconds)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _saveJobSettings(),
                  validator: (val) {
                    if (val == null || val.isEmpty) return null;
                    if (double.tryParse(val) == null) return 'Enter a number';
                    return null;
                  },
                ),
              ),
            ],
          ),
        const SizedBox(height: 16),

        const Text('Features',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Wrap(
          spacing: 16,
          children: [
            CheckboxListTile(
              title: const Text('Filter Profanity'),
              value: _profanityFilter,
              onChanged: (v) => setState(() => _profanityFilter = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Filter Music'),
              value: _filterMusic,
              onChanged: (v) => setState(() => _filterMusic = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Enable Summarization'),
              value: _enableSummarization,
              onChanged: (v) => setState(() => _enableSummarization = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Enable Live Notes'),
              value: _enableLiveNotes,
              onChanged: (v) => setState(() => _enableLiveNotes = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Enable Speaker Diarization'),
              value: _enableDiarization,
              onChanged: (v) => setState(() => _enableDiarization = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Enable AI Assistant'),
              value: _enableAIAssistant,
              onChanged: (v) => setState(() => _enableAIAssistant = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Save Session (logging)'),
              value: _saveSession,
              onChanged: (v) => setState(() => _saveSession = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: const Text('Distinguish unknown speakers'),
              value: _distinguishUnknownSpeakers,
              onChanged: (v) =>
                  setState(() => _distinguishUnknownSpeakers = v!),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
          ],
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – JOB HISTORY
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildJobHistory() {
    if (_jobHistory.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: Column(
          children: [
            Icon(Icons.history, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              'No previous jobs for this video',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 4),
            Text(
              'Start your first processing job above',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.history, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'Job History (${_jobHistory.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_sweep, size: 20),
                  onPressed: _clearAllHistory,
                  tooltip: 'Clear all history',
                  color: Colors.red,
                ),
              ],
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _jobHistory.length,
            separatorBuilder: (_, __) => Divider(color: Colors.grey[200]),
            itemBuilder: (context, index) {
              final job = _jobHistory[index];
              final timestamp = DateTime.tryParse(job['timestamp'] ?? '');
              final dateStr = timestamp != null
                  ? '${timestamp.day}/${timestamp.month}/${timestamp.year} '
                      '${timestamp.hour.toString().padLeft(2, '0')}:'
                      '${timestamp.minute.toString().padLeft(2, '0')}'
                  : job['date'] ?? 'Unknown date';
              final sessionName = job['session_name'] ?? 'Unknown Session';
              final status = job['status'] ?? 'Unknown';
              final hasOutput = job['has_output'] ?? false;
              final sessionId = job['session_id'] ?? '';
              final sessionUrl = job['session_url'] ?? '';
              final outputFiles = job['output_files'] ?? 0;
              final isProcessing = status.contains('Processing') || !hasOutput;

              Color statusColor;
              IconData statusIcon;
              if (hasOutput) {
                statusColor = Colors.green;
                statusIcon = Icons.check_circle;
              } else if (isProcessing) {
                statusColor = Colors.orange;
                statusIcon = Icons.hourglass_empty;
              } else {
                statusColor = Colors.grey;
                statusIcon = Icons.help_outline;
              }

              return Material(
                color: Colors.transparent,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: statusColor.withValues(alpha: 0.2),
                    child: Icon(statusIcon, size: 20, color: statusColor),
                  ),
                  title: Text(
                    sessionName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ID: ${sessionId.length > 20 ? '${sessionId.substring(0, 20)}...' : sessionId}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      // One line: date • input → output • TTS languages.
                      // The TTS segment is omitted entirely when the
                      // job asked for no synthesized audio, so the
                      // line stays short for translation-only runs.
                      Builder(
                        builder: (_) {
                          final rawAudio =
                              (job['audio_languages'] ?? '').toString().trim();
                          final ttsSuffix = rawAudio.isEmpty
                              ? ''
                              : '  •  🔊 $rawAudio';
                          return Text(
                            '📅 $dateStr'
                            '  •  ${job['input_languages'] ?? 'N/A'}'
                            ' → ${job['output_languages'] ?? 'N/A'}'
                            '$ttsSuffix',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          );
                        },
                      ),
                      // ── Pipeline ──
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.dns_outlined,
                                size: 11, color: Colors.blueGrey[400]),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                '${job['pipeline'] ?? internalServerUrl}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.blueGrey[600],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── Email used for the KIT token ──
                      // Always rendered so the field is visible even on
                      // entries whose token has not been captured yet.
                      // An empty value shows as a muted placeholder
                      // instead of disappearing.
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Builder(
                          builder: (_) {
                            final rawEmail =
                                (job['email'] ?? '').toString().trim();
                            final hasEmail = rawEmail.isNotEmpty;
                            return Row(
                              children: [
                                Icon(
                                  Icons.alternate_email,
                                  size: 11,
                                  color: hasEmail
                                      ? Colors.indigo[400]
                                      : Colors.grey[400],
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    hasEmail
                                        ? rawEmail
                                        : '— no email in token',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hasEmail
                                          ? Colors.indigo[600]
                                          : Colors.grey[500],
                                      fontStyle: hasEmail
                                          ? FontStyle.normal
                                          : FontStyle.italic,
                                      fontWeight: hasEmail
                                          ? FontWeight.w500
                                          : FontWeight.normal,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      // ── NEW: remarks (rendered only when set) ──
                      if ((job['remarks'] ?? '').toString().trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.sticky_note_2_outlined,
                                  size: 11, color: Colors.amber[700]),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  job['remarks'].toString(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.brown[600],
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (hasOutput)
                        Text(
                          '📁 $outputFiles file${outputFiles > 1 ? 's' : ''} available',
                          style: TextStyle(
                              fontSize: 11, color: Colors.green[700]),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasOutput)
                        Icon(
                          Icons.file_download_done,
                          size: 18,
                          color: Colors.green[400],
                        ),
                      const SizedBox(width: 4),
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      PopupMenuButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: (value) {
                          if (value == 'view' && sessionId.isNotEmpty) {
                            _viewHistoricalOutput(sessionId, sessionUrl);
                          } else if (value == 'check' &&
                              sessionId.isNotEmpty) {
                            _checkHistoricalOutput(sessionId);
                          } else if (value == 'remarks') {
                            _editJobRemarks(sessionId);
                          } else if (value == 'delete') {
                            _deleteJobFromHistory(sessionId);
                          } else if (value == 'open' &&
                              sessionUrl.isNotEmpty) {
                            html.window.open(sessionUrl, '_blank');
                          }
                        },
                        itemBuilder: (context) => [
                          if (hasOutput || sessionUrl.isNotEmpty)
                            const PopupMenuItem(
                              value: 'view',
                              child: Row(
                                children: [
                                  Icon(Icons.folder_open, size: 18),
                                  SizedBox(width: 8),
                                  Text('View Output'),
                                ],
                              ),
                            ),
                          if (!hasOutput)
                            const PopupMenuItem(
                              value: 'check',
                              child: Row(
                                children: [
                                  Icon(Icons.refresh,
                                      size: 18, color: Colors.blue),
                                  SizedBox(width: 8),
                                  Text('Check Status',
                                      style: TextStyle(color: Colors.blue)),
                                ],
                              ),
                            ),
                          // ── NEW ──
                          const PopupMenuItem(
                            value: 'remarks',
                            child: Row(
                              children: [
                                Icon(Icons.edit_note,
                                    size: 18, color: Colors.brown),
                                SizedBox(width: 8),
                                Text('Edit remarks',
                                    style: TextStyle(color: Colors.brown)),
                              ],
                            ),
                          ),
                          if (sessionUrl.isNotEmpty)
                            const PopupMenuItem(
                              value: 'open',
                              child: Row(
                                children: [
                                  Icon(Icons.open_in_new, size: 18),
                                  SizedBox(width: 8),
                                  Text('Open Session'),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete,
                                    size: 18, color: Colors.red),
                                SizedBox(width: 8),
                                Text('Delete',
                                    style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  onTap: () {
                    if (hasOutput) {
                      _viewHistoricalOutput(sessionId, sessionUrl);
                    } else {
                      _checkHistoricalOutput(sessionId);
                    }
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – SERVER PICKER
  // ═══════════════════════════════════════════════════════════════════

 // session_detail_screen.dart  (replacement)

  Widget _buildServerPicker() {
    final currentLabel =  labelForServer(internalServerUrl);

    // Built-ins first, then user-added ones.
    final allServers = ServerConfigService.allServers;
    final customSet = ServerConfigService.customServers.toSet();

    return Card(
      elevation: 1,
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

            // ── Add a custom server ─────────────────────────────
            IconButton(
              tooltip: 'Add custom server',
              icon: const Icon(Icons.add_circle_outline, size: 20),
              onPressed: _showAddServerDialog,
            ),

            // ── Switch between servers ──────────────────────────
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
                  final label = labelForServer(url);

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
                                        label,
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
                          // Remove button for custom entries only.
                          if (isCustom)
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () async {
                                await ServerConfigService
                                    .removeCustomServer(url);
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
                        Text(
                          'Add server…',
                          style: TextStyle(color: Colors.blue),
                        ),
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
  
  // ═══════════════════════════════════════════════════════════════════
  //  SERVER PICKER — ADD-CUSTOM-SERVER DIALOG
  // ═══════════════════════════════════════════════════════════════════

  /// Dialog that lets the user type an arbitrary `lt2srv-XXXX` host.
  ///
  /// Validation is done in two places:
  ///   • the form validator below (immediate feedback),
  ///   • `ServerConfigService.addCustomServer` (defence in depth).
  ///
  /// Both call `isAllowedInternalServer`, which is the *same* regex the
  /// backend's `_is_allowed_server` uses. If you ever change one, change
  /// the other.
  Future<void> _showAddServerDialog() async {
    final controller = TextEditingController(text: 'https://lt2srv-');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
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
                      if (ServerConfigService.allServers
                          .contains(normalised)) {
                        return 'Already in the list';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: const Text(
                      'Accepted examples:\n'
                      '  https://lt2srv.iar.kit.edu\n'
                      '  https://lt2srv-backup.iar.kit.edu\n'
                      '  https://lt2srv-sscherrer.isl.iar.kit.edu\n'
                      '  https://lt2srv-alice.isl.iar.kit.edu',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
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
                if (url.endsWith('/')) {
                  url = url.substring(0, url.length - 1);
                }
                Navigator.pop(ctx, url);
              },
            ),
          ],
        );
      },
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
        break;

      case AddResult.duplicate:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That server is already in the list.')),
        );
        break;

      case AddResult.invalid:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That does not look like a valid lt2srv host.'),
          ),
        );
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – OUTPUT CHECK
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildOutputCheckSection() {
    if (!_hasSessionId) {
      // No active session on this device, but the user may still have
      // past jobs in the history. Don't draw the full "Current Session"
      // card — just a one-line hint pointing at the history panel.
      if (_jobHistory.isEmpty) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.grey[600], size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No session is active on this device right now. '
                'Use Job History below to check or view past sessions.',
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
            ),
          ],
        ),
      );
    }

    final currentJobIndex =
        _jobHistory.indexWhere((job) => job['session_id'] == _savedSessionId);

    final bool hasOutput = currentJobIndex != -1 &&
        (_jobHistory[currentJobIndex]['has_output'] ?? false);
    final int outputFiles = currentJobIndex != -1
        ? (_jobHistory[currentJobIndex]['output_files'] ?? 0)
        : 0;

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.folder_outlined, color: Colors.blue),
              SizedBox(width: 8),
              Text(
                'Current Session',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Session ID: $_savedSessionId',
            style: const TextStyle(fontSize: 12),
          ),
          if (hasOutput) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.check_circle, size: 14, color: Colors.green),
                const SizedBox(width: 4),
                Text(
                  '✅ Output ready ($outputFiles files)',
                  style: TextStyle(fontSize: 12, color: Colors.green[700]),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (_outputStatus.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _outputStatus,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
                    Builder(
            builder: (context) {
              final currentJob = currentJobIndex != -1
                  ? _jobHistory[currentJobIndex]
                  : null;
              final currentStatus =
                  (currentJob?['status'] as String? ?? '');
              final isRunning = !hasOutput &&
                  (currentStatus.contains('Processing') ||
                      currentStatus.isEmpty);

              return Row(
                children: [
                  if (!hasOutput)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isCheckingOutput ? null : _checkOutput,
                        icon: _isCheckingOutput
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: Text(
                          _isCheckingOutput ? 'Checking...' : 'Check Status',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  if (isRunning) ...[
                    if (!hasOutput) const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isCancelling ? null : _cancelJob,
                        icon: _isCancelling
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.cancel, size: 18),
                        label: Text(
                          _isCancelling ? 'Cancelling…' : 'Cancel',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                  if (hasOutput) ...[
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final job = _jobHistory.firstWhere(
                            (j) => j['session_id'] == _savedSessionId,
                            orElse: () => {},
                          );
                          _viewHistoricalOutput(
                            _savedSessionId,
                            job['session_url'] ?? _savedSessionUrl,
                          );
                        },
                        icon: const Icon(Icons.folder_open),
                        label: Text('View Output ($outputFiles files)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isCheckingOutput ? null : _checkOutput,
                        icon: _isCheckingOutput
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 16),
                        label: Text(
                          _isCheckingOutput ? 'Checking...' : 'Refresh',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  WIDGET BUILDERS – RESPONSE DISPLAY
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildResponseDisplay() {
    if (!_showResponse) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
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
              const Icon(Icons.info_outline, color: Colors.blue),
              const SizedBox(width: 8),
              const Text(
                'Response from Server:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () {
                  setState(() {
                    _showResponse = false;
                  });
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[700]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '✅ Upload Successful!',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          if (_sessionUrl.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.link, color: Colors.blue),
                      SizedBox(width: 8),
                      Text(
                        '📎 Session Link:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: InkWell(
                      onTap: () {
                        html.window.open(_sessionUrl, '_blank');
                      },
                      child: Text(
                        _sessionUrl,
                        style: TextStyle(
                          color: Colors.blue[700],
                          decoration: TextDecoration.underline,
                          fontSize: 13,
                        ),
                        softWrap: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          if (_videoKeyResponse.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.video_label, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Video Key: $_videoKeyResponse',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Response Preview:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _stripHtmlTags(_responseHtml),
                    style: const TextStyle(fontSize: 12),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_sessionUrl.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: () {
                    html.window.open(_sessionUrl, '_blank');
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open Session'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ElevatedButton.icon(
                onPressed: _showFullResponseDialog,
                icon: const Icon(Icons.open_in_full),
                label: const Text('View Full Response'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _showResponse = false;
                  });
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showFullResponseDialog() {
    final String cleanText = _stripHtmlTags(_responseHtml);
    final String videoKey = _extractVideoKey(_responseHtml);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blue),
            SizedBox(width: 8),
            Text('Full Server Response'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_sessionUrl.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '📎 Session Link:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      InkWell(
                        onTap: () {
                          html.window.open(_sessionUrl, '_blank');
                          Navigator.pop(context);
                        },
                        child: Text(
                          _sessionUrl,
                          style: TextStyle(
                            color: Colors.blue[700],
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      if (_sessionId.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Session ID: $_sessionId',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (videoKey.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Video Key: $videoKey',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      cleanText.isNotEmpty ? cleanText : _responseMessage,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (_sessionUrl.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                html.window.open(_sessionUrl, '_blank');
                Navigator.pop(context);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open Session'),
            ),
        ],
      ),
    );
  }

  Widget _buildLiveProgressPanel() {
    if (!_hasSessionId || _savedSessionId.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: JobProgressPanel(
        key: ValueKey('job-progress-$_savedSessionId'),
        sessionId: _savedSessionId,
        onComplete: () {
          if (!mounted) return;
          setState(() {
            _outputStatus =
                '✅ Processing complete! Click "View Output" to browse files.';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Processing complete'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          _checkOutput();
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  MAIN BUILD
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Detail'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Copy link',
            onPressed: () {
              final url = '${html.window.location.origin}'
                  '/session-detail/${widget.videoKey}';
              html.window.navigator.clipboard?.writeText(url);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Link copied: $url')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          // Asymmetric padding: normal top/sides, but extra bottom so
          // floating SnackBars (they anchor to the bottom of the screen)
          // don't sit on top of the green Start Processing button or
          // any other interactive control near the end of the form.
          padding: EdgeInsets.only(
            top: _pagePadding(context),
            left: _pagePadding(context),
            right: _pagePadding(context),
            bottom: 160,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Session detail header (thumbnail, title, meta) ───
              _buildDetailHeader(),
              SizedBox(height: _sectionGap(context)),

              // ─── Server picker ───
              _buildServerPicker(),
              SizedBox(height: _sectionGap(context)),

              // ─── Connect / Token section ───
              Container(
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
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _isConnected
                                  ? Icons.check_circle
                                  : Icons.info_outline,
                              color: _isConnected
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isConnected
                                  ? 'Connected'
                                  : 'Not connected — required for processing',
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: _isConnected
                                    ? Colors.green
                                    : Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _showTokenInput = !_showTokenInput;
                                  if (!_showTokenInput) {
                                    _tokenStatus = '';
                                    _tokenController.clear();
                                    _showBookmarklet = false;
                                  }
                                });
                              },
                              icon: Icon(
                                _showTokenInput
                                    ? Icons.keyboard_arrow_up
                                    : Icons.vpn_key,
                                size: 18,
                              ),
                              label: Text(_showTokenInput
                                  ? 'Hide Token'
                                  : 'Manual Token'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.blue,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              onPressed:
                                  _isConnecting ? null : _connectToInternal,
                              tooltip:
                                  _isConnected ? 'Reconnect' : 'Connect',
                              icon: _isConnecting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _isConnected
                                          ? Icons.link
                                          : Icons.link_off,
                                    ),
                            ),
                          ],
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
                          hintText:
                              'Token will appear here after pasting...',
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          errorText: _tokenStatus.contains('❌')
                              ? _tokenStatus
                              : null,
                          helperText: _tokenStatus.contains('✅')
                              ? _tokenStatus
                              : null,
                          helperStyle:
                              const TextStyle(color: Colors.green),
                          suffixIcon: _tokenController.text.isNotEmpty
                              ? IconButton(
                                  icon:
                                      const Icon(Icons.clear, size: 18),
                                  onPressed: () => setState(
                                      () => _tokenController.clear()),
                                )
                              : null,
                        ),
                        maxLines: 2,
                        minLines: 1,
                        onChanged: (_) {
                          if (_tokenStatus.isNotEmpty &&
                              !_tokenStatus.startsWith('📋')) {
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
                              icon: const Icon(Icons.open_in_new,
                                  size: 18),
                              label: const Text('Get Token'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.blue,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _pasteFromClipboard,
                              icon: const Icon(Icons.content_paste,
                                  size: 18),
                              label: const Text('Paste Token'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
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
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
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
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 16),
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
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ),

                      const SizedBox(height: 8),

                      InkWell(
                        onTap: () => setState(
                            () => _showBookmarklet = !_showBookmarklet),
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
                            border:
                                Border.all(color: Colors.blueGrey[200]!),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Create a bookmark whose URL is the text '
                                'below. Then on the /gettoken page, click '
                                'it once to copy the token.',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.blueGrey),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: Colors.blueGrey[100]!),
                                ),
                                child: const SelectableText(
                                  _bookmarkletJs,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
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
              ),
              SizedBox(height: _sectionGap(context)),
              // ─── 1st: Job History (collapsible) ──────────────────
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    controller: _jobHistoryTileController,
                    leading: Icon(
                      Icons.history,
                      color: _jobHistory.isNotEmpty
                          ? Colors.blue
                          : Colors.grey,
                    ),
                    title: Row(
                      children: [
                        const Text(
                          'Job History',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_jobHistory.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_jobHistory.length}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                    initiallyExpanded: false,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _isLoadingHistory
                            ? const Center(
                                child: CircularProgressIndicator())
                            : _buildJobHistory(),
                      ),
                      // ─── Collapse from the bottom ───────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () =>
                                _jobHistoryTileController.collapse(),
                            icon: const Icon(
                                Icons.keyboard_arrow_up, size: 18),
                            label: const Text('Collapse'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: _sectionGap(context)),

              // ─── 2nd: Job Settings (collapsible) ─────────────────
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    controller: _jobSettingsTileController,
                    leading:
                        const Icon(Icons.settings, color: Colors.blue),
                    title: Row(
                      children: [
                        const Text(
                          'Job Settings',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
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
                      ],
                    ),
                    initiallyExpanded: false,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: _buildSettingsPanel(),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _showSavedSettingsDialog,
                                icon: const Icon(Icons.visibility_outlined, size: 18),
                                label: const Text('View saved settings'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _saveCurrentAsPreset,
                                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                                label: const Text('Save as preset'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _loadPresetDialog,
                                icon: const Icon(Icons.download_outlined, size: 18),
                                label: const Text('Load preset'),
                              ),
                              TextButton.icon(
                                onPressed: () => _jobSettingsTileController.collapse(),
                                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                                label: const Text('Collapse'),
                              ),
                            ],
                          ),
                        ),
                      ],
                  ),
                ),
              ),
              SizedBox(height: _sectionGap(context)),
              // ─── Start Processing ───
              ElevatedButton(
                onPressed: _isSubmitting ? null : _submitJob,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 18),
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: _isSubmitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Start Processing'),
              ),

              // ─── Live progress panel ───
              _buildLiveProgressPanel(),

              // ─── Output check section ───
              _buildOutputCheckSection(),

              // ─── Response display ───
              _buildResponseDisplay(),

              SizedBox(height: _sectionGap(context)),
            ],
          ),
        ),
      ),
    );
  }
}
// ═══════════════════════════════════════════════════════════════════
//  FULLSCREEN VIDEO DIALOG
// ═══════════════════════════════════════════════════════════════════

class _FullscreenVideoDialog extends StatefulWidget {
  final VideoPlayerController controller;
  const _FullscreenVideoDialog({required this.controller});

  @override
  State<_FullscreenVideoDialog> createState() => _FullscreenVideoDialogState();
}

class _FullscreenVideoDialogState extends State<_FullscreenVideoDialog> {
  bool _showControls = true;
  Timer? _hideTimer;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_tick);
    _focus.dispose();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _bumpControls() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _togglePlay() {
    final c = widget.controller;
    c.value.isPlaying ? c.pause() : c.play();
    _bumpControls();
  }

  void _seekBy(Duration delta) {
    final c = widget.controller;
    final target = c.value.position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > c.value.duration ? c.value.duration : target);
    c.seekTo(clamped);
    _bumpControls();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final value = c.value;
    final dur = value.duration;
    final pos = value.position;
    final progress = dur.inMilliseconds == 0
        ? 0.0
        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final aspect = value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio;

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: KeyboardListener(
        focusNode: _focus,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
          } else if (key == LogicalKeyboardKey.space) {
            _togglePlay();
          } else if (key == LogicalKeyboardKey.arrowRight) {
            _seekBy(const Duration(seconds: 5));
          } else if (key == LogicalKeyboardKey.arrowLeft) {
            _seekBy(const Duration(seconds: -5));
          } else if (key == LogicalKeyboardKey.keyF) {
            Navigator.of(context).pop(); // toggle out of fullscreen
          }
        },
        child: MouseRegion(
          onHover: (_) => _bumpControls(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_showControls) {
                setState(() => _showControls = false);
              } else {
                _bumpControls();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: VideoPlayer(c),
                  ),
                ),

                // ── Top bar ────────────────────────────────────────
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _showControls ? 1 : 0,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.75),
                            Colors.transparent,
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.movie, color: Colors.white),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Fullscreen',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Exit fullscreen (Esc)',
                            icon: const Icon(Icons.fullscreen_exit,
                                color: Colors.white, size: 28),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Bottom bar ─────────────────────────────────────
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _showControls ? 1 : 0,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.75),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                _fmt(pos),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ]),
                              ),
                              Expanded(
                                child: Slider(
                                  value: progress,
                                  onChanged: (v) {
                                    c.seekTo(Duration(
                                      milliseconds: (dur.inMilliseconds * v)
                                          .toInt(),
                                    ));
                                    _bumpControls();
                                  },
                                ),
                              ),
                              Text(
                                _fmt(dur),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ]),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                iconSize: 32,
                                color: Colors.white,
                                icon: const Icon(Icons.replay_10),
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: -10)),
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                iconSize: 52,
                                color: Colors.white,
                                icon: Icon(
                                  value.isPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                ),
                                onPressed: _togglePlay,
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                iconSize: 32,
                                color: Colors.white,
                                icon: const Icon(Icons.forward_10),
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: 10)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}