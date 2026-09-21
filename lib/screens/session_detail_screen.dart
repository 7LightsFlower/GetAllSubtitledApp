// session_detail_screen.dart  (merged with job_configuration_screen.dart)
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/screens/session_output_screen.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:asr_live_translator/widgets/job_progress_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:asr_live_translator/theme/responsive.dart';
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
  });

  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final segments = (json['segments'] as List?)
            ?.map((e) => Segment.fromJson(e))
            .toList() ??
        [];
    return SessionDetail(
      key: json['key'] as String,
      name: json['name'] as String? ?? 'Untitled',
      fileName: json['file_name'] as String? ?? 'video.mp4',
      uploaded: DateTime.parse(json['uploaded'] as String),
      lastOpened: json['last_opened'] != null
          ? DateTime.parse(json['last_opened'] as String)
          : null,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      fileSize: json['file_size'] as int? ?? 0,
      segmentCount: json['segment_count'] as int? ?? 0,
      languages: (json['languages'] as List?)?.cast<String>() ?? [],
      thumbnailUrl: json['thumbnail_url'] as String?,
      videoUrl: json['video_url'] as String?,
      segments: segments,
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
  // ─── Session detail state ────────────────────────────────────────
  SessionDetail? _detail;
  bool _isLoadingDetail = true;
  String? _detailError;

  VideoPlayerController? _videoController;
  bool _isVideoReady = false;

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
  final List<String> _inputLanguages = ['en'];
  final List<String> _outputLanguages = ['de'];
  final List<String> _audioLanguages = ['de'];

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

  // Settings panel collapsed state
  bool _settingsExpanded = false;

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
  String _outputStatus = '';

  // Job history
  List<Map<String, dynamic>> _jobHistory = [];
  bool _isLoadingHistory = false;

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

  // ─── Init ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _sessionNameController = TextEditingController();
    final now = DateTime.now();
    _date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _initServerConfig();    
    _checkConnection();
    _loadJobHistory();
    _loadSavedSessionId();
    _fetchDetail();
  }

  Future<void> _initServerConfig() async {
    await ServerConfigService.load();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    _sessionNameController.dispose();
    _sessionNameController.dispose();
    _topicNameController.dispose();
    _speakerNameController.dispose();
    _shortenController.dispose();
    _muteController.dispose();
    _pauseController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  String _getDefaultSessionName() {
    final now = DateTime.now();
    final dateTimeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final videoName = _detail?.name ?? 'Video';
    return '$videoName – $dateTimeStr';
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
        Uri.parse('$authBaseUrl/video_detail/${widget.videoKey}'),
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
            _topicNameController.text = _sessionNameController.text;
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

  Future<void> _loadSavedSessionId() async {
    final sessionId = await InternalAuthService.getSessionId(widget.videoKey);
    if (!mounted) return;
    if (sessionId != null && sessionId.isNotEmpty) {
      setState(() {
        _savedSessionId = sessionId;
        _hasSessionId = true;
        _outputStatus =
            '✅ Session ID loaded: $sessionId\nClick "Check Output" to see results.';
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  JOB HISTORY
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _loadJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      final jsonString = prefs.getString(key);
      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> history = jsonDecode(jsonString);
        if (!mounted) return;
        setState(() {
          _jobHistory = history.cast<Map<String, dynamic>>();
          _jobHistory.sort((a, b) =>
              (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));
        });
      }
    } catch (e) {
      if (kDebugMode) print('Error loading job history: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _saveJobToHistory({
    required String sessionId,
    required String sessionUrl,
    required String sessionName,
    required String status,
    required bool hasOutput,
    int outputFiles = 0,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';

      final existingIndex = _jobHistory
          .indexWhere((job) => job['session_id'] == sessionId);

      if (existingIndex != -1) {
        _jobHistory[existingIndex]['status'] = status;
        _jobHistory[existingIndex]['has_output'] = hasOutput;
        if (outputFiles > 0) {
          _jobHistory[existingIndex]['output_files'] = outputFiles;
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
          'availability': _availability,
        };
        _jobHistory.insert(0, jobEntry);
      }

      if (_jobHistory.length > 20) {
        _jobHistory = _jobHistory.sublist(0, 20);
      }

      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);

      if (mounted) setState(() {});
    } catch (e) {
      if (kDebugMode) print('Error saving job history: $e');
    }
  }

  Future<void> _saveJobHistoryToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);
    } catch (e) {
      if (kDebugMode) print('Error saving job history: $e');
    }
  }

  Future<void> _deleteJobFromHistory(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';

      _jobHistory.removeWhere((job) => job['session_id'] == sessionId);
      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job removed from history')),
        );
      }
    } catch (e) {
      if (kDebugMode) print('Error deleting job: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting job: $e')),
        );
      }
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
        final prefs = await SharedPreferences.getInstance();
        final key = 'job_history_${widget.videoKey}';
        await prefs.remove(key);
        setState(() {
          _jobHistory.clear();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('History cleared')),
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
    if (!mounted) return;

    // Reset auth-related state because it was issued by the previous host.
    setState(() {
      _isConnected = false;
      _outputStatus = '';
      _tokenStatus = '🔀 Switched to: $url';
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
    if (token == null || token.isEmpty) {
      throw Exception(
          'Not connected to internal server. Please click "Connect" or set a manual token first.');
    }
    return token;
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
      final token = await _getToken();
      final url = '$flaskServerUrl/session_output/$_savedSessionId';

      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        if (totalFiles > 0) {
          final jobIndex = _jobHistory
              .indexWhere((job) => job['session_id'] == _savedSessionId);

          if (jobIndex != -1) {
            setState(() {
              _jobHistory[jobIndex]['has_output'] = true;
              _jobHistory[jobIndex]['status'] = 'Completed ✅';
              _jobHistory[jobIndex]['output_files'] = totalFiles;
            });
            await _saveJobHistoryToPrefs();
          } else {
            await _saveJobToHistory(
              sessionId: _savedSessionId,
              sessionUrl: _savedSessionUrl,
              sessionName: _sessionNameController.text.trim(),
              status: 'Completed ✅',
              hasOutput: true,
              outputFiles: totalFiles,
            );
          }

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

  Future<void> _checkHistoricalOutput(String sessionId) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔄 Checking output status...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final token = await _getToken();
      final url = '$flaskServerUrl/session_output/$sessionId';

      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        final jobIndex =
            _jobHistory.indexWhere((job) => job['session_id'] == sessionId);

        if (jobIndex != -1) {
          if (totalFiles > 0) {
            setState(() {
              _jobHistory[jobIndex]['has_output'] = true;
              _jobHistory[jobIndex]['status'] = 'Completed ✅';
              _jobHistory[jobIndex]['output_files'] = totalFiles;
            });
            await _saveJobHistoryToPrefs();

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
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text('⏳ Still processing... No output files found yet.'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Failed to check output: ${response.statusCode}'),
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
    setState(() {
      if (_inputLanguages.contains(lang)) {
        _inputLanguages.remove(lang);
      } else {
        _inputLanguages.add(lang);
      }
    });
  }

  void _toggleOutputLanguage(String lang) {
    setState(() {
      if (_outputLanguages.contains(lang)) {
        _outputLanguages.remove(lang);
      } else {
        _outputLanguages.add(lang);
      }
    });
  }

  void _toggleAudioLanguage(String lang) {
    setState(() {
      if (_audioLanguages.contains(lang)) {
        _audioLanguages.remove(lang);
      } else {
        _audioLanguages.add(lang);
      }
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SUBMIT
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _submitJob() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSubmitting = true);

    try {
      final token = await _getToken();
      if (kDebugMode) print('🚀 [UPLOAD] Using token: $token');

      const userEmail = 'admin@example.com';

      final localMediaUrl = Uri.parse('$authBaseUrl/media/${widget.videoKey}');
      if (kDebugMode) {
        print('🌐 [DEBUG] Fetching video from local server: $localMediaUrl');
      }

      http.Response localResponse = await http.get(localMediaUrl);
      if (localResponse.statusCode != 200) {
        final fallbackUrl =
            Uri.parse('$authBaseUrl/videos/${widget.videoKey}/download');
        final fallbackResponse = await http.get(fallbackUrl);
        if (fallbackResponse.statusCode != 200) {
          throw Exception(
            'Failed to fetch video from local server (HTTP ${fallbackResponse.statusCode}). '
            'Body: ${fallbackResponse.body}',
          );
        }
        localResponse = fallbackResponse;
      }

      final videoBytes = localResponse.bodyBytes;
      if (videoBytes.isEmpty) {
        throw Exception('Video file is empty.');
      }

      if (kDebugMode) {
        print('✅ [DEBUG] Video fetched from local: ${videoBytes.length} bytes');
      }

      await _uploadToInternalServer(
        videoBytes: videoBytes,
        fileName: _detail?.fileName ?? '${widget.videoKey}.mp4',
        token: token,
        userEmail: userEmail,
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
      if (kDebugMode) print('❌ [DEBUG] Exception caught: $e');
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

  Future<void> _uploadToInternalServer({
    required List<int> videoBytes,
    required String fileName,
    required String token,
    required String userEmail,
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
    const uploadUrl = '$flaskServerUrl/upload';

    final formData = html.FormData();

    formData.append('token', token);
    formData.append('path', '/home/$userEmail');
    formData.append('name', sessionName);
    formData.append('topicname', topicName);
    formData.append('date', date);
    formData.append('speakername', speakerName);
    formData.append('availability', availability);
    formData.append('format', format);
    formData.append('smartChaptering', smartChaptering);
    formData.append('errorCorrection', errorCorrection);
    formData.append('ttsQualityMode', ttsQualityMode);

    for (final lang in inputLanguages) {
      formData.append('language', lang);
    }
    for (final lang in outputLanguages) {
      formData.append('mtLanguage', lang);
    }
    for (final lang in audioLanguages) {
      formData.append('audioLanguage', lang);
    }

    if (profanityFilter) formData.append('profanity', '1');
    if (filterMusic) formData.append('filter_music', '1');
    if (enableSummarization) formData.append('summarization', '1');
    if (enableLiveNotes) formData.append('notes', '1');
    if (enableDiarization) formData.append('saasr', '1');
    if (enableAIAssistant) formData.append('aiassistant', '1');
    if (saveSession) formData.append('logging', '1');
    if (distinguishUnknownSpeakers) {
      formData.append('distinguish_unknown_speakers', '1');
    }

    formData.append('legals', '1');
    formData.append('profile', 'profile_1');
    formData.append('profile_names', '');
    formData.append('shorten', shorten);
    formData.append('mute', mute.toString());
    formData.append('pause', pause.toString());
    formData.append('save_profile', '1');

    for (final rate in postproduction) {
      formData.append('postproduction', rate);
    }

    final blob = html.Blob([videoBytes]);

    String uploadFileName = fileName;
    if (!uploadFileName.toLowerCase().endsWith('.mp4')) {
      uploadFileName = '$uploadFileName.mp4';
    }
    formData.appendBlob('videofile', blob, uploadFileName);

    final request = html.HttpRequest();
    request.open('POST', uploadUrl);
    request.send(formData);
    await request.onLoadEnd.first;

    final status = request.status ?? 0;
    final responseText = request.responseText;
    final finalUrl = request.responseUrl;

    bool historySaved = false;

    if (status >= 200 && status < 300) {
      if (mounted) {
        try {
          final data = jsonDecode(responseText ?? '{}');
          setState(() {
            _responseMessage = data['data']?['raw_response'] ??
                data['data']?['message'] ??
                data['message'] ??
                'Upload successful!';
            _responseHtml = data['html'] ?? '';
            _sessionUrl = data['session_url'] ?? '';
            _sessionId = data['session_id']?.toString() ?? '';
            _videoKeyResponse = data['video_key'] ?? '';
            _showResponse = true;
          });
          _printSessionLink();
        } catch (_) {
          final parsedSessionId =
              _parseHtmlResponseAndReturnSessionId(responseText ?? '');
          if (parsedSessionId != null && parsedSessionId.isNotEmpty) {
            if (mounted) {
              await InternalAuthService.saveSessionId(
                  widget.videoKey, parsedSessionId);
            }
          }

          if (mounted) {
            setState(() {
              _responseMessage = responseText ?? 'Upload successful!';
              _showResponse = true;
            });
          }
          _printSessionLink();
        }
      }

      if (finalUrl != null && finalUrl.contains('/archivesession/')) {
        final sessionId =
            finalUrl.split('/archivesession/')[-1].split('/')[0];
        if (mounted) {
          setState(() {
            _sessionId = sessionId;
            _sessionUrl = finalUrl;
            _savedSessionId = sessionId;
            _savedSessionUrl = finalUrl;
            _hasSessionId = true;
            _outputStatus = '✅ Upload complete! Session ID: $sessionId\n'
                'Click "Check Output" to see if processing is finished.';
          });

          await InternalAuthService.saveSessionId(widget.videoKey, sessionId);

          if (!historySaved) {
            await _saveJobToHistory(
              sessionId: sessionId,
              sessionUrl: finalUrl,
              sessionName: _sessionNameController.text.trim(),
              status: 'Processing... ⏳',
              hasOutput: false,
            );
            historySaved = true;
          }

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
        return;
      }

      try {
        final data = jsonDecode(responseText ?? '');
        final sessionId = data['session_id']?.toString();
        if (sessionId != null && sessionId.isNotEmpty) {
          if (mounted) {
            setState(() {
              _sessionId = sessionId;
              _sessionUrl = data['session_url'] ?? '';
              _savedSessionId = sessionId;
              _savedSessionUrl = data['session_url'] ?? '';
              _hasSessionId = true;
              _outputStatus = '✅ Upload complete! Session ID: $sessionId\n'
                  'Click "Check Output" to see if processing is finished.';
            });

            await InternalAuthService.saveSessionId(widget.videoKey, sessionId);

            if (!historySaved) {
              await _saveJobToHistory(
                sessionId: sessionId,
                sessionUrl: data['session_url'] ?? '',
                sessionName: _sessionNameController.text.trim(),
                status: 'Processing... ⏳',
                hasOutput: false,
              );
              historySaved = true;
            }

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
          return;
        }
      } catch (_) {}

      return;
    }
  }

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
    if (_sessionUrl.isNotEmpty && kDebugMode) {
      if (kDebugMode) {
        print('═══════════════════════════════════════════════════════════');
      }
      if (kDebugMode) print('📎 SESSION LINK:');
      if (kDebugMode) print(_sessionUrl);
      if (kDebugMode) {
        print('═══════════════════════════════════════════════════════════');
      }
    }
    if (_sessionId.isNotEmpty && kDebugMode) {
      if (kDebugMode) print('🆔 SESSION ID: $_sessionId');
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

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
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

  Widget _infoChip(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade700),
          const SizedBox(width: 4),
          Text('$label: ',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.normal)),
        ],
      ),
    );
  }

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
                        maxWidth:
                            MediaQuery.of(context).size.width * 0.9,
                        maxHeight: Responsive.of(context).videoHeight,
                      ),
                      child: _isVideoReady
                          ? VideoPlayerWidget(
                              controller: _videoController,
                              isReady: _isVideoReady,
                              onPlayPause: _togglePlayPause,
                              onSeek: _seekTo,
                              height: Responsive.of(context).videoHeight,
                            )
                          : const Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
  
        const SizedBox(height: 16),

        // Title & file name
        Text(
          detail.name,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          detail.fileName,
          style: const TextStyle(color: Colors.grey, fontSize: 14),
        ),
        const SizedBox(height: 16),

        // Metadata chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _infoChip(Icons.calendar_today, 'Uploaded',
                _formatDate(detail.uploaded)),
            _infoChip(Icons.timer, 'Duration',
                _formatDuration(detail.duration)),
            _infoChip(Icons.speed, 'FPS', detail.fps.toStringAsFixed(1)),
            _infoChip(Icons.storage, 'Size', _formatBytes(detail.fileSize)),
            _infoChip(Icons.layers, 'Segments',
                detail.segmentCount.toString()),
            if (detail.lastOpened != null)
              _infoChip(Icons.history, 'Last opened',
                  _formatDate(detail.lastOpened!)),
          ],
        ),

        // Languages
        if (detail.languages.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Languages',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: detail.languages
                .map((lang) => Chip(label: Text(lang)))
                .toList(),
          ),
        ],

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

        // Input Languages
        const Text('Input Languages',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: inputLangCodes.map((code) {
            final displayName = LanguageConfig.getInputLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _inputLanguages.contains(code),
              onSelected: (selected) => _toggleInputLanguage(code),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Output Languages
        const Text('Output Languages (Translation)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: outputLangCodes.map((code) {
            final displayName = LanguageConfig.getOutputLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _outputLanguages.contains(code),
              onSelected: (selected) => _toggleOutputLanguage(code),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Audio Languages
        const Text('Generated Audio Languages',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: audioLangCodes.map((code) {
            final displayName = LanguageConfig.getAudioLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _audioLanguages.contains(code),
              onSelected: (selected) => _toggleAudioLanguage(code),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Availability',
          value: _availability,
          options: _availabilityOptions,
          onChanged: (val) => setState(() => _availability = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Presentation Format',
          value: _format,
          options: _formatOptions,
          onChanged: (val) => setState(() => _format = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Smart Chaptering',
          value: _smartChaptering,
          options: _chapteringOptions,
          onChanged: (val) => setState(() => _smartChaptering = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'TTS Quality Mode',
          value: _ttsQualityMode,
          options: _ttsQualityOptions,
          onChanged: (val) => setState(() => _ttsQualityMode = val!),
        ),
        const SizedBox(height: 16),

        _buildDropdownField<String>(
          label: 'Error Correction',
          value: _errorCorrection,
          options: _errorCorrectionOptions,
          onChanged: (val) => setState(() => _errorCorrection = val!),
        ),
        const SizedBox(height: 16),

        _buildMultiSelectChips(
          label: 'Shortening (Post-production)',
          selected: _postproduction,
          allOptions: _postproductionOptions,
          onChanged: (newList) =>
              setState(() => _postproduction..clear()..addAll(newList)),
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
                      Text(
                        '📅 $dateStr • ${job['input_languages'] ?? 'N/A'} → ${job['output_languages'] ?? 'N/A'}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
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
  //  WIDGET BUILDERS – OUTPUT CHECK
  // ═══════════════════════════════════════════════════════════════════

  Widget _buildOutputCheckSection() {
    if (!_hasSessionId) return const SizedBox.shrink();

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
          Row(
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
                            child: CircularProgressIndicator(strokeWidth: 2),
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

          if (_savedSessionId.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session ID: $_savedSessionId',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

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
                  if (_sessionId.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.fingerprint,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Session ID:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                                Text(
                                  _sessionId,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[700],
                                  ),
                                  softWrap: true,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
          // ── Server picker ─────────────────────────────────────────
          PopupMenuButton<String>(
            tooltip: 'Choose internal server',
            icon: const Icon(Icons.dns_outlined),
            onSelected: _changeServer,
            itemBuilder: (context) => internalServerOptions.map((url) {
              final isSelected = url == internalServerUrl;
              final label = internalServerLabels[url] ?? url;
              return PopupMenuItem<String>(
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
                          Text(
                            label,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            url,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: Icon(_isConnected ? Icons.link : Icons.link_off),
            onPressed: _isConnecting ? null : _connectToInternal,
            tooltip: _isConnected ? 'Reconnect' : 'Connect',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Session detail header (thumbnail, title, meta) ───
              _buildDetailHeader(),
              const SizedBox(height: 24),
              // ─── Active server indicator ───
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.blueGrey[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blueGrey[100]!),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.dns_outlined, size: 16, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    const Text('Server: ', style: TextStyle(fontWeight: FontWeight.w500)),
                    Expanded(
                      child: Text(
                        internalServerUrl,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // ─── Job History card ───
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
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
                    initiallyExpanded: _jobHistory.isNotEmpty,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _isLoadingHistory
                            ? const Center(
                                child: CircularProgressIndicator())
                            : _buildJobHistory(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ─── Job Settings (expandable) ───
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    leading: const Icon(Icons.settings, color: Colors.blue),
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
                            '${_inputLanguages.length} in · ${_outputLanguages.length} out',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    initiallyExpanded: _settingsExpanded,
                    onExpansionChanged: (expanded) {
                      setState(() {
                        _settingsExpanded = expanded;
                      });
                    },
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildSettingsPanel(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

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
                                  : Icons.error,
                              color:
                                  _isConnected ? Colors.green : Colors.red,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isConnected ? 'Connected' : 'Not connected',
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: _isConnected
                                    ? Colors.green
                                    : Colors.red,
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
                            ElevatedButton(
                              onPressed: _isConnecting
                                  ? null
                                  : _connectToInternal,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isConnected
                                    ? Colors.grey
                                    : Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                              child: _isConnecting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : Text(_isConnected
                                      ? 'Reconnect'
                                      : 'Connect'),
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
                                  icon: const Icon(Icons.clear, size: 18),
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
                              icon: const Icon(Icons.open_in_new, size: 18),
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
              const SizedBox(height: 16),

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
            ],
          ),
        ),
      ),
    );
  }
}