// working_screen.dart
import 'dart:async';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/screens/session_detail_screen.dart';
import 'package:asr_live_translator/widgets/job_progress_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http_parser/http_parser.dart';

// ─── Helper for robust date parsing ────────────────────────────
DateTime _parseDateTime(String dateStr) {
  try {
    return DateTime.parse(dateStr);
  } catch (_) {
    final cleaned = dateStr.replaceFirst(RegExp(r'\+00:00(?=Z)'), '');
    try {
      return DateTime.parse(cleaned);
    } catch (_) {
      return DateTime.now();
    }
  }
}

// ─── Data model ──────────────────────────────────────────────────
class VideoProject {
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
  final bool segmentationDone;
  final int segmentationProgress;

  // Green-screen prep state. Populated by the backend's
  // /videos response; defaults keep older servers working.
  final String? greenscreenFileName;
  final String greenscreenStatus;   // pending | building | ready | failed
  final int greenscreenProgress;    // 0..100

  VideoProject({
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
    required this.segmentationDone,
    required this.segmentationProgress,
    required this.greenscreenFileName,
    required this.greenscreenStatus,
    required this.greenscreenProgress,
  });

  factory VideoProject.fromJson(Map<String, dynamic> json) {
    return VideoProject(
      key: json['key'] as String? ??
          'fallback-${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Untitled',
      fileName: json['file_name'] as String? ?? 'video.mp4',
      uploaded: json['uploaded'] != null
          ? _parseDateTime(json['uploaded'] as String)
          : DateTime.now(),
      lastOpened: json['last_opened'] != null
          ? _parseDateTime(json['last_opened'] as String)
          : null,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      fileSize: json['file_size'] as int? ?? 0,
      segmentCount: json['segment_count'] as int? ?? 0,
      languages: (json['languages'] as List?)?.cast<String>() ?? [],
      thumbnailUrl: json['thumbnail_url'] as String?,
      segmentationDone: json['segmentation_done'] as bool? ?? false,
      segmentationProgress: json['segmentation_progress'] as int? ?? 0,
      greenscreenFileName: json['greenscreen_file_name'] as String?,
      greenscreenStatus:
          json['greenscreen_status'] as String? ?? 'pending',
      greenscreenProgress: json['greenscreen_progress'] as int? ?? 0,
    );
  }
}

// ─── Import status enums and classes ────────────────────────────
enum ImportState { pending, downloading, completed, error }

class ImportVideoStatus {
  final String url;
  ImportState state;
  String message;
  double progress;

  ImportVideoStatus({
    required this.url,
    this.state = ImportState.pending,
    this.message = 'Pending',
    this.progress = 0.0,
  });
}

// ─── Main screen ────────────────────────────────────────────────
class WorkingScreen extends StatefulWidget {
  const WorkingScreen({super.key});

  @override
  State<WorkingScreen> createState() => _WorkingScreenState();
}

class _WorkingScreenState extends State<WorkingScreen> {
  List<VideoProject> _projects = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _sortMode = 'newest';
  double _storageUsed = 0.0;
  double _storageLimit = 50.0;
  String? _listError;

  // Track which project keys already had the trigger fired, so we
  // don't spam the backend on every refresh.
  final Set<String> _greenscreenTriggered = {};

  // ─── Lifecycle ────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _fetchProjects();
  }

  Future<void> _fetchProjects() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _listError = null;
    });

    final url = Uri.parse('$authBaseUrl/videos');

    if (kDebugMode) {
      print('📡 GET $url  (authBaseUrl="$authBaseUrl")');
    }

    http.Response response;
    try {
      response = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (kDebugMode) print('❌ Timed out after 15 s');
      if (mounted) {
        setState(() {
          _listError =
              'The backend did not respond within 15 seconds. '
              'Make sure the Flask server is running on port 5000.';
          _isLoading = false;
        });
      }
      return;
    } on http.ClientException catch (e) {
      if (kDebugMode) print('❌ ClientException: $e');
      if (mounted) {
        setState(() {
          _listError =
              'Cannot reach the backend at $authBaseUrl.\n\n'
              'Check that the Flask server is running and that the URL '
              'in constants.dart is correct.';
          _isLoading = false;
        });
      }
      return;
    } catch (e) {
      if (kDebugMode) print('❌ Unexpected network error: $e');
      if (mounted) {
        setState(() {
          _listError = 'Network error while loading projects: $e';
          _isLoading = false;
        });
      }
      return;
    }

    // ── Check the response before parsing it. ──
    final contentType = response.headers['content-type'] ?? '';
    final bodyPreview = response.body.length > 200
        ? response.body.substring(0, 200)
        : response.body;

    if (kDebugMode) {
      print('📡 status=${response.statusCode} content-type=$contentType');
      print('📡 body preview: $bodyPreview');
    }

    if (response.statusCode != 200) {
      if (mounted) {
        setState(() {
          _listError =
              'Backend returned HTTP ${response.statusCode}.\n\n'
              '${_shorten(bodyPreview, 200)}';
          _isLoading = false;
        });
      }
      return;
    }

    if (!contentType.contains('application/json') &&
        bodyPreview.trimLeft().startsWith('<')) {
      if (kDebugMode) {
        print('❌ Got HTML instead of JSON — wrong URL?');
      }
      if (mounted) {
        setState(() {
          _listError =
              'The URL "$authBaseUrl/videos" returned an HTML page, not '
              'JSON. This usually means authBaseUrl is pointing at the '
              'web host instead of the Flask backend.\n\n'
              'Fix: set authBaseUrl to your Flask server, e.g. '
              '"http://localhost:5000" when running locally.';
          _isLoading = false;
        });
      }
      return;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      if (kDebugMode) print('❌ JSON parse failed: $e');
      if (mounted) {
        setState(() {
          _listError =
              'The backend returned something that is not valid JSON.\n\n'
              '${_shorten(bodyPreview, 200)}';
          _isLoading = false;
        });
      }
      return;
    }

    final projects = (data['projects'] as List?)
            ?.map((e) {
              try {
                return VideoProject.fromJson(e as Map<String, dynamic>);
              } catch (err) {
                if (kDebugMode) print('❌ Error parsing project: $err');
                return null;
              }
            })
            .whereType<VideoProject>()
            .toList() ??
        [];

    if (!mounted) return;
    setState(() {
      _projects = projects;
      _storageUsed =
          (data['storage_used_gb'] as num?)?.toDouble() ?? 0.0;
      _storageLimit =
          (data['storage_limit_gb'] as num?)?.toDouble() ?? 50.0;
      _isLoading = false;
    });

    // Fire-and-forget: ask the backend to prepare a green-screen for
    // any project that still needs one. The server answers immediately
    // (202) and does the work in a background thread.
    _triggerGreenscreenForPendingProjects();
  }

  Future<void> _triggerGreenscreenForPendingProjects() async {
    final toTrigger = _projects
        .where((p) => _projectNeedsGreenscreen(p))
        .where((p) => !_greenscreenTriggered.contains(p.key))
        .toList();

    if (toTrigger.isEmpty) return;

    for (final p in toTrigger) {
      _greenscreenTriggered.add(p.key);
      try {
        await http.post(
          Uri.parse('$authBaseUrl/prepare-greenscreen/${p.key}'),
          headers: {'Content-Type': 'application/json'},
        );
        if (kDebugMode) {
          print('🧪 prepare-greenscreen requested for ${p.key}');
        }
      } catch (e) {
        // If the request itself fails, allow a retry on the next
        // refresh by forgetting the key.
        _greenscreenTriggered.remove(p.key);
        if (kDebugMode) {
          print('prepare-greenscreen failed for ${p.key}: $e');
        }
      }
    }

    // Single refresh after a short delay. The server does the heavy
    // lifting; we just need the UI to catch up on the new status.
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) _fetchProjects();
    });
  }

  bool _projectNeedsGreenscreen(VideoProject p) {
    final s = p.greenscreenStatus;
    return s == 'pending' || s == 'failed';
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  String _shorten(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }

  void _showBackendHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline),
            SizedBox(width: 8),
            Text('How to fix this'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('1. Start the backend server:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  'cd GetAllSubtitledApp/lib\n'
                  'python backend.py',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text('2. Confirm the URL in constants.dart:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  "const String authBaseUrl    = 'http://localhost:5000';\n"
                  "const String flaskServerUrl = 'http://localhost:5000';",
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text('3. Test from a terminal:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  'curl http://localhost:5000/videos\n'
                  '# should print JSON, not HTML',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  'Current authBaseUrl: "$authBaseUrl"',
                  style: const TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ],
            ),
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

  // ─── YouTube URL detection and extraction ─────────────────────
  bool _isYouTubeUrl(String url) {
    final youtubePatterns = [
      r'youtube\.com/watch\?v=',
      r'youtu\.be/',
      r'youtube\.com/shorts/',
      r'youtube\.com/embed/',
      r'youtube\.com/v/',
      r'youtube\.com/e/',
      r'm\.youtube\.com/',
    ];
    final lowerUrl = url.toLowerCase();
    return youtubePatterns.any((pattern) => lowerUrl.contains(pattern));
  }

  String _extractYouTubeVideoId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/watch\?v=([^&]+)'),
      RegExp(r'youtu\.be/([^?]+)'),
      RegExp(r'youtube\.com/shorts/([^?]+)'),
      RegExp(r'youtube\.com/embed/([^?]+)'),
      RegExp(r'youtube\.com/v/([^?]+)'),
      RegExp(r'youtube\.com/e/([^?]+)'),
      RegExp(r'm\.youtube\.com/watch\?v=([^&]+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) {
        return match.group(1)!;
      }
    }

    return '';
  }

  Future<String?> _getYouTubeVideoUrl(String youtubeUrl) async {
    try {
      final videoId = _extractYouTubeVideoId(youtubeUrl);
      if (videoId.isEmpty) {
        throw Exception('Could not extract video ID from YouTube URL');
      }

      final serverUrl = '$flaskServerUrl/api/youtube-info';

      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': youtubeUrl}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['url'] != null) {
          return data['url'];
        } else {
          throw Exception(data['error'] ?? 'Failed to get video URL');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error getting YouTube video: $e');
      return null;
    }
  }

  Future<void> _importYouTubeDirectly(String youtubeUrl) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _YouTubeDownloadDialog(
        youtubeUrl: youtubeUrl,
        onComplete: () {
          if (mounted) {
            _fetchProjects();
            _showSnackBar('✅ YouTube video downloaded and imported!');
          }
        },
        onError: (msg) {
          if (mounted) _showSnackBar('❌ $msg', isError: true);
        },
      ),
    );
  }

  void _showYouTubeImportDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download YouTube Video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the YouTube video URL:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://youtube.com/watch?v=...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(ctx);
                _importYouTubeDirectly(url);
              }
            },
            child: const Text('Download & Import'),
          ),
        ],
      ),
    );
  }

  // ─── Import from text ─────────────────────────────────────────
  Future<void> _importVideosFromText() async {
    if (!mounted) return;

    final controller = TextEditingController();
    bool autoSegmentation = true;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Import Videos from Text'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste video URLs (one per line):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                width: 400,
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    hintText:
                        'https://example.com/video1.mp4\nhttps://youtube.com/watch?v=abc123\nhttps://example.com/video2.mp4\n...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: autoSegmentation,
                    onChanged: (v) => setState(() => autoSegmentation = v!),
                  ),
                  const Text('Auto Segmentation for all videos'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Supports: direct video URLs (MP4, WebM, MOV) and YouTube links',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 4),
              Text(
                'Note: YouTube links may not work reliably. Consider using a dedicated YouTube downloader service.',
                style: TextStyle(fontSize: 11, color: Colors.orange[700]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Import Videos'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;

    final text = controller.text.trim();
    final urls = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (urls.isEmpty) {
      _showSnackBar('No URLs found in text.', isError: true);
      return;
    }

    await _importVideosFromUrls(urls, autoSegmentation);
  }

  bool _isValidUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.scheme == 'http' || uri.scheme == 'https';
    } catch (_) {
      return false;
    }
  }

  Future<void> _importVideosFromUrls(
      List<String> urls, bool autoSegmentation) async {
    if (!mounted) return;

    List<Map<String, String>> resolvedUrls = [];
    List<String> errors = [];

    for (final url in urls) {
      if (_isYouTubeUrl(url)) {
        final videoUrl = await _getYouTubeVideoUrl(url);
        if (videoUrl != null) {
          resolvedUrls.add({'original': url, 'resolved': videoUrl});
          if (kDebugMode) print('✅ Resolved YouTube URL: $url -> $videoUrl');
        } else {
          errors.add('Could not resolve YouTube URL: $url');
          if (kDebugMode) print('❌ Failed to resolve YouTube URL: $url');
        }
      } else if (_isValidUrl(url)) {
        resolvedUrls.add({'original': url, 'resolved': url});
      } else {
        errors.add('Invalid URL: $url');
      }
    }

    if (errors.isNotEmpty) {
      final errorMessage = errors.join('\n');
      _showSnackBar('⚠️ Errors:\n$errorMessage', isError: true);
    }

    if (resolvedUrls.isEmpty) {
      _showSnackBar('No valid video URLs found to import.', isError: true);
      return;
    }

    final finalUrls = resolvedUrls.map((e) => e['resolved']!).toList();

    showDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ImportVideosDialog(
        urls: finalUrls,
        autoSegmentation: autoSegmentation,
        onComplete: () {
          if (mounted) {
            Navigator.pop(ctx);
            _fetchProjects();
            final errorCount = errors.length;
            final message = errorCount > 0
                ? '✅ Import completed! ($errorCount failed)'
                : '✅ Import completed!';
            _showSnackBar(message);
          }
        },
        onError: (error) {
          if (mounted) {
            _showSnackBar('❌ Import error: $error', isError: true);
          }
        },
      ),
    );
  }

  // ─── Navigation and actions ───────────────────────────────────
  void _openSessionDetail(String videoKey) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveTranscriptScreen(videoKey: videoKey),
      ),
    );
  }

  void _openEnhancement(String videoKey) {
    Navigator.pushNamed(context, '/enhancement', arguments: videoKey);
  }

  void _showContextMenu(BuildContext context, VideoProject project) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Open Session Detail'),
              onTap: () {
                Navigator.pop(ctx);
                _openSessionDetail(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Open Enhancement'),
              onTap: () {
                Navigator.pop(ctx);
                _openEnhancement(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('Video Information'),
              onTap: () {
                Navigator.pop(ctx);
                _showVideoInfo(project);
              },
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('Show Generated Segments'),
              onTap: () {
                Navigator.pop(ctx);
                _showGeneratedSegments(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: const Text('Show Progress'),
              onTap: () {
                Navigator.pop(ctx);
                _showProgress(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: const Text('Video Segmentation'),
              onTap: () {
                Navigator.pop(ctx);
                _showSegmentationSettings(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('Show Segments'),
              onTap: () {
                Navigator.pop(ctx);
                _showSegmentsList(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename Project'),
              onTap: () {
                Navigator.pop(ctx);
                _editProjectName(project);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Delete Project',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteProject(project.key);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showVideoInfo(VideoProject project) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Video Information'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Name: ${project.name}'),
            Text('File: ${project.fileName}'),
            Text('Duration: ${project.duration.toStringAsFixed(2)} s'),
            Text('FPS: ${project.fps.toStringAsFixed(1)}'),
            Text('File Size: ${_formatBytes(project.fileSize)}'),
            Text('Uploaded: ${_formatDate(project.uploaded)}'),
            if (project.lastOpened != null)
              Text('Last Opened: ${_formatDate(project.lastOpened!)}'),
            Text('Segments: ${project.segmentCount}'),
            Text('Green-screen: ${project.greenscreenStatus}'),
          ],
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

  void _showGeneratedSegments(String videoKey) {
    Navigator.pushNamed(context, '/generated_segments', arguments: videoKey);
  }

  void _showProgress(String videoKey) {
    Navigator.pushNamed(context, '/progress', arguments: videoKey);
  }

  void _showSegmentationSettings(String videoKey) {
    Navigator.pushNamed(context, '/segmentation', arguments: videoKey);
  }

  void _showSegmentsList(String videoKey) {
    Navigator.pushNamed(context, '/segments_list', arguments: videoKey);
  }

  // ─── Delete ───────────────────────────────────────────────────
  Future<void> _deleteProject(String videoKey) async {
    if (!mounted) return;

    final confirm = await _confirmAction(
        'Delete this project permanently? This cannot be undone.');
    if (!confirm) return;

    try {
      final response = await http.post(
        Uri.parse('$authBaseUrl/delete-video/$videoKey'),
        headers: {'Content-Type': 'application/json'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showSnackBar('Project deleted.');
        _greenscreenTriggered.remove(videoKey);
        _fetchProjects();
      } else {
        _showSnackBar(
          'Failed to delete (HTTP ${response.statusCode}).',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<bool> _confirmAction(String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirm'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ─── Edit name ────────────────────────────────────────────────
  Future<void> _editProjectName(VideoProject project) async {
    if (!mounted) return;

    final controller = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Project Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('$authBaseUrl/update-project-name/${project.key}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'project_name': newName}),
        );
        if (!mounted) return;
        if (response.statusCode == 200) {
          _showSnackBar('Project name updated.');
          _fetchProjects();
        } else {
          _showSnackBar('Failed to update name.', isError: true);
        }
      } catch (e) {
        if (mounted) _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  // ─── Upload ───────────────────────────────────────────────────
  Future<void> _uploadVideo() async {
    if (!mounted) return;
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );
    if (result == null || result.files.isEmpty) return;

    final pickedFile = result.files.single;
    final fileName = pickedFile.name;
    final bytes = pickedFile.bytes;

    if (bytes == null) {
      _showSnackBar('Failed to read file bytes', isError: true);
      return;
    }

    showDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _UploadDialog(
        bytes: bytes,
        fileName: fileName,
        mode: UploadMode.chunked,
        onUploadComplete: _fetchProjects,
      ),
    );
  }

  // ─── Logout ───────────────────────────────────────────────────
  Future<void> _logoutPublic() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await InternalAuthService.clearTokens();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  // ─── UI ───────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => _showYouTubeImportDialog(),
            tooltip: 'Download YouTube Video',
          ),
          IconButton(
            icon: const Icon(Icons.text_snippet),
            onPressed: _importVideosFromText,
            tooltip: 'Import from text links',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchProjects,
            tooltip: 'Refresh list',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logoutPublic,
            tooltip: 'Logout from public server',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search by name or file...',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) {
                            setState(() => _searchQuery = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _sortMode,
                        items: const [
                          DropdownMenuItem(
                              value: 'newest', child: Text('Newest First')),
                          DropdownMenuItem(
                              value: 'oldest', child: Text('Oldest First')),
                          DropdownMenuItem(
                              value: 'last-opened',
                              child: Text('Last Opened')),
                          DropdownMenuItem(
                              value: 'az', child: Text('Name A → Z')),
                          DropdownMenuItem(
                              value: 'za', child: Text('Name Z → A')),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _sortMode = value);
                        },
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _uploadVideo,
                        icon: const Icon(Icons.upload),
                        label: const Text('Upload'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Storage used (input videos)',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[600]),
                          ),
                          Text(
                            '${_storageUsed.toStringAsFixed(2)} GB / $_storageLimit GB',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: _storageUsed / _storageLimit,
                        backgroundColor: Colors.grey[300],
                        valueColor:
                            const AlwaysStoppedAnimation(Colors.blue),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(child: _buildGrid()),
              ],
            ),
    );
  }

  Widget _buildGrid() {
    if (_listError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.orange.shade200),
              ),
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.cloud_off,
                            size: 32, color: Colors.orange.shade800),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Cannot load projects',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      _listError!,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _fetchProjects,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _showBackendHelp,
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: const Text('How to fix'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final filtered = _projects.where((p) {
      final q = _searchQuery.toLowerCase();
      return p.name.toLowerCase().contains(q) ||
          p.fileName.toLowerCase().contains(q);
    }).toList();

    filtered.sort((a, b) {
      switch (_sortMode) {
        case 'newest':
          return b.uploaded.compareTo(a.uploaded);
        case 'oldest':
          return a.uploaded.compareTo(b.uploaded);
        case 'last-opened':
          final aTime = a.lastOpened ?? a.uploaded;
          final bTime = b.lastOpened ?? b.uploaded;
          return bTime.compareTo(aTime);
        case 'az':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'za':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        default:
          return 0;
      }
    });

    if (filtered.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 80, color: Colors.grey),
            SizedBox(height: 16),
            Text('No projects found', style: TextStyle(fontSize: 18)),
            Text('Upload a video to get started.',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.5,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildCard(filtered[index]),
    );
  }

  Widget _buildCard(VideoProject project) {
    return GestureDetector(
      onLongPress: () => _showContextMenu(context, project),
      onTap: () => _openSessionDetail(project.key),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: project.thumbnailUrl != null &&
                        project.thumbnailUrl!.isNotEmpty
                    ? Image.network(
                        project.thumbnailUrl!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (context, error, stackTrace) =>
                            _buildThumbnailPlaceholder(project),
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            color: Colors.grey[300],
                            child: Center(
                              child: CircularProgressIndicator(
                                value: loadingProgress.expectedTotalBytes !=
                                        null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                        loadingProgress.expectedTotalBytes!
                                    : null,
                              ),
                            ),
                          );
                        },
                      )
                    : _buildThumbnailPlaceholder(project),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(6.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => _editProjectName(project),
                      child: Text(
                        project.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      project.fileName,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        Text(
                          _formatDuration(project.duration),
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '• ${project.segmentCount} segs',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _formatDate(project.uploaded),
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.grey[400],
                      ),
                    ),
                    _buildPipelineStatus(project),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          onPressed: () => _deleteProject(project.key),
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red, size: 18),
                          tooltip: 'Delete',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => _openSessionDetail(project.key),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            textStyle: const TextStyle(fontSize: 9),
                            minimumSize: const Size(0, 26),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Open'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailPlaceholder(VideoProject project) {
    return Container(
      color: Colors.grey[800],
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.grey[800]!, Colors.grey[900]!],
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: 36,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _formatDuration(project.duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 6,
            right: 6,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                project.fileName.split('.').last.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineStatus(VideoProject project) {
    final gs = project.greenscreenStatus;

    if (gs == 'ready') {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: 11),
          SizedBox(width: 2),
          Text('Green-screen ready',
              style: TextStyle(fontSize: 8, color: Colors.green)),
        ],
      );
    }
    if (gs == 'building') {
      final pct = project.greenscreenProgress;
      return Row(
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: pct > 0 ? pct / 100.0 : null,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            pct > 0 ? 'Preparing $pct%' : 'Preparing…',
            style: const TextStyle(fontSize: 8, color: Colors.blue),
          ),
        ],
      );
    }
    if (gs == 'failed') {
      return const Row(
        children: [
          Icon(Icons.error_outline, color: Colors.orange, size: 11),
          SizedBox(width: 2),
          Text('Prep failed',
              style: TextStyle(fontSize: 8, color: Colors.orange)),
        ],
      );
    }

    // Fall back to the old segmentation-based indicator when the
    // backend hasn't told us anything yet.
    if (project.segmentationDone) {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: 11),
          SizedBox(width: 2),
          Text('Done', style: TextStyle(fontSize: 8, color: Colors.green)),
        ],
      );
    }
    return const Row(
      children: [
        Icon(Icons.hourglass_empty, color: Colors.grey, size: 11),
        SizedBox(width: 2),
        Text('Not prepared',
            style: TextStyle(fontSize: 8, color: Colors.grey)),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String _formatDuration(double seconds) {
    final duration = Duration(seconds: seconds.round());
    final minutes = duration.inMinutes;
    final remainingSeconds = duration.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

// ─── Import Videos Dialog ──────────────────────────────────────
class _ImportVideosDialog extends StatefulWidget {
  final List<String> urls;
  final bool autoSegmentation;
  final VoidCallback onComplete;
  final Function(String) onError;

  const _ImportVideosDialog({
    required this.urls,
    required this.autoSegmentation,
    required this.onComplete,
    required this.onError,
  });

  @override
  State<_ImportVideosDialog> createState() => _ImportVideosDialogState();
}

class _ImportVideosDialogState extends State<_ImportVideosDialog> {
  List<ImportVideoStatus> _statuses = [];
  bool _isComplete = false;

  @override
  void initState() {
    super.initState();
    _statuses = widget.urls.map((url) => ImportVideoStatus(url: url)).toList();
    _startImport();
  }

  Future<void> _startImport() async {
    for (int i = 0; i < _statuses.length; i++) {
      if (!mounted) break;

      final status = _statuses[i];
      setState(() {
        status.state = ImportState.downloading;
        status.message = 'Downloading...';
      });

      try {
        final response = await http.get(
          Uri.parse(status.url),
          headers: {
            'Accept': 'video/*, application/octet-stream',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept-Encoding': 'identity',
          },
        );

        if (response.statusCode != 200) {
          throw Exception('Failed to download: HTTP ${response.statusCode}');
        }
        if (response.bodyBytes.isEmpty) {
          throw Exception('Downloaded file is empty');
        }

        final fileName = _extractFileNameFromUrl(status.url, response);

        setState(() => status.message = 'Uploading...');

        await _uploadVideoToServer(
          bytes: response.bodyBytes,
          fileName: fileName,
          autoSegmentation: widget.autoSegmentation,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                status.progress = progress;
                status.message = 'Uploading ${progress.toStringAsFixed(0)}%';
              });
            }
          },
        );

        setState(() {
          status.state = ImportState.completed;
          status.message = '✓ Complete';
          status.progress = 100;
        });
      } catch (e) {
        setState(() {
          status.state = ImportState.error;
          status.message = '✗ Error: $e';
        });
        if (mounted) {
          widget.onError('Failed to import ${status.url}: $e');
        }
      }
    }

    setState(() => _isComplete = true);
    widget.onComplete();
  }

  Future<void> _uploadVideoToServer({
    required Uint8List bytes,
    required String fileName,
    required bool autoSegmentation,
    required Function(double) onProgress,
  }) async {
    const chunkSize = 5 * 1024 * 1024;
    final totalBytes = bytes.length;
    final totalChunks = (totalBytes / chunkSize).ceil();

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end =
          (i + 1) * chunkSize > totalBytes ? totalBytes : (i + 1) * chunkSize;
      final chunk = bytes.sublist(start, end);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$authBaseUrl/upload-chunk'),
      );
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          chunk,
          filename: fileName,
          contentType: MediaType('video', 'mp4'),
        ),
      );
      request.fields['filename'] = fileName;
      request.fields['chunk_index'] = i.toString();
      request.fields['total_chunks'] = totalChunks.toString();

      final response = await request.send();
      if (response.statusCode != 200) {
        throw Exception('Chunk upload failed: ${response.statusCode}');
      }

      onProgress(((i + 1) / totalChunks) * 100);
    }

    final finishResponse = await http.post(
      Uri.parse('$authBaseUrl/finish-upload'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'filename': fileName,
        'auto_segmentation': autoSegmentation,
      }),
    );
    if (finishResponse.statusCode != 200) {
      throw Exception('Finish upload failed');
    }
  }

  String _extractFileNameFromUrl(String url, http.Response response) {
    final disposition = response.headers['content-disposition'];
    if (disposition != null) {
      final match = RegExp(r'filename="([^"]+)"').firstMatch(disposition);
      if (match != null) return match.group(1)!;
    }
    try {
      final lastSegment = Uri.parse(url).path.split('/').last;
      if (lastSegment.contains('.')) return lastSegment;
    } catch (_) {}
    return 'video_${DateTime.now().millisecondsSinceEpoch}'
        '.${_getFileExtensionFromUrl(url)}';
  }

  String _getFileExtensionFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mp4')) return 'mp4';
    if (lower.contains('.webm')) return 'webm';
    if (lower.contains('.mov')) return 'mov';
    if (lower.contains('.avi')) return 'avi';
    if (lower.contains('.mkv')) return 'mkv';
    if (lower.contains('.flv')) return 'flv';
    if (lower.contains('.wmv')) return 'wmv';
    if (lower.contains('.m4v')) return 'm4v';
    return 'mp4';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isComplete ? 'Import Complete' : 'Importing Videos'),
      content: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isComplete)
              LinearProgressIndicator(
                value: _statuses.isEmpty
                    ? 0
                    : _statuses
                            .where((s) => s.state == ImportState.completed)
                            .length /
                        _statuses.length,
              ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _statuses.length,
                itemBuilder: (ctx, index) {
                  final status = _statuses[index];
                  return ListTile(
                    dense: true,
                    leading: _buildStatusIcon(status.state),
                    title: Text(
                      _truncateUrl(status.url, 60),
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Text(
                      status.message,
                      style: TextStyle(
                        fontSize: 12,
                        color: status.state == ImportState.error
                            ? Colors.red
                            : status.state == ImportState.completed
                                ? Colors.green
                                : Colors.grey,
                      ),
                    ),
                    subtitle: status.state == ImportState.downloading &&
                            status.progress > 0
                        ? LinearProgressIndicator(
                            value: status.progress / 100, minHeight: 4)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_isComplete)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildStatusIcon(ImportState state) {
    switch (state) {
      case ImportState.pending:
        return const Icon(Icons.pending, color: Colors.grey, size: 20);
      case ImportState.downloading:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ImportState.completed:
        return const Icon(Icons.check_circle, color: Colors.green, size: 20);
      case ImportState.error:
        return const Icon(Icons.error, color: Colors.red, size: 20);
    }
  }

  String _truncateUrl(String url, int maxLength) {
    if (url.length <= maxLength) return url;
    return '${url.substring(0, maxLength - 3)}...';
  }
}

// ─── Upload Dialog ─────────────────────────────────────────────
class _UploadDialog extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final VoidCallback onUploadComplete;
  final UploadMode mode;

  const _UploadDialog({
    required this.bytes,
    required this.fileName,
    required this.onUploadComplete,
    this.mode = UploadMode.chunked,
  });

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

enum UploadMode { chunked, forward, direct }

class _UploadDialogState extends State<_UploadDialog> {
  double _progress = 0.0;
  bool _isUploading = false;
  String _statusText = 'Ready';
  bool _autoSegmentation = true;

  String? _sessionId;
  bool _sessionComplete = false;
  String? _videoKey;

  @override
  void initState() {
    super.initState();
    _startUpload();
  }

  Future<void> _startUpload() async {
    setState(() {
      _isUploading = true;
      _statusText = 'Uploading…';
    });

    const chunkSize = 5 * 1024 * 1024;
    final totalBytes = widget.bytes.length;
    final totalChunks = (totalBytes / chunkSize).ceil();

    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize > totalBytes
            ? totalBytes
            : (i + 1) * chunkSize;
        final chunk = widget.bytes.sublist(start, end);

        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$authBaseUrl/upload-chunk'),
        );
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            chunk,
            filename: widget.fileName,
            contentType: MediaType('video', 'mp4'),
          ),
        );
        request.fields['filename'] = widget.fileName;
        request.fields['chunk_index'] = i.toString();
        request.fields['total_chunks'] = totalChunks.toString();

        final response = await request.send();
        if (response.statusCode != 200) {
          throw Exception('Chunk upload failed: ${response.statusCode}');
        }

        if (!mounted) return;
        setState(() {
          _progress = ((i + 1) / totalChunks) * 100;
          _statusText = 'Uploading ${_progress.toStringAsFixed(0)}%';
        });
      }

      final finishResponse = await http.post(
        Uri.parse('$authBaseUrl/finish-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': widget.fileName,
          'auto_segmentation': _autoSegmentation,
        }),
      );
      if (finishResponse.statusCode != 200) {
        throw Exception('Finish upload failed');
      }

      final finishData =
          jsonDecode(finishResponse.body) as Map<String, dynamic>;
      _videoKey = (finishData['project'] as Map?)?['key'] as String?;

      if (!mounted) return;
      setState(() {
        _statusText = 'Upload complete';
        _isUploading = false;
      });

      widget.onUploadComplete();

      switch (widget.mode) {
        case UploadMode.chunked:
          _closeSoon();
          break;
        case UploadMode.forward:
          await _forwardToInternal();
          break;
        case UploadMode.direct:
          _closeSoon();
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error: $e';
        _isUploading = false;
      });
    }
  }

  Future<void> _forwardToInternal() async {
    if (_videoKey == null) {
      _closeSoon();
      return;
    }

    setState(() {
      _statusText = 'Submitting to the server…';
      _isUploading = true;
      _progress = 0;
    });

    try {
      final token = await InternalAuthService.getToken();
      final resp = await http.post(
        Uri.parse('$authBaseUrl/upload'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'video_key': _videoKey,
          'token': token,
          'name': widget.fileName.replaceAll('.mp4', ''),
        }),
      );

      if (resp.statusCode != 200) {
        throw Exception('Upload failed: ${resp.statusCode}');
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final sessionId = data['session_id'] as String?;
      if (sessionId == null) {
        throw Exception('Server did not return a session id');
      }

      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _isUploading = false;
        _statusText = 'Processing on the server…';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Forward error: $e';
        _isUploading = false;
      });
    }
  }

  void _closeSoon() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) Navigator.pop(context, true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionId != null) return _buildProcessingDialog(_sessionId!);
    return _buildUploadDialog();
  }

  Widget _buildUploadDialog() {
    return AlertDialog(
      title: const Text('Uploading Video'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress / 100),
          const SizedBox(height: 12),
          Text(_statusText),
          const SizedBox(height: 12),
          if (!_isUploading && _progress < 100)
            Row(
              children: [
                Checkbox(
                  value: _autoSegmentation,
                  onChanged: (v) =>
                      setState(() => _autoSegmentation = v ?? false),
                ),
                const Text('Auto Segmentation'),
              ],
            ),
        ],
      ),
      actions: [
        if (!_isUploading)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildProcessingDialog(String sessionId) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: Row(
        children: [
          Icon(
            _sessionComplete ? Icons.check_circle : Icons.hourglass_top,
            color: _sessionComplete ? Colors.green : Colors.blue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sessionComplete
                  ? 'Processing complete'
                  : 'Processing on the server',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: JobProgressPanel(
            sessionId: sessionId,
            onComplete: () {
              if (!mounted) return;
              setState(() => _sessionComplete = true);
              widget.onUploadComplete();
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(_sessionComplete ? 'Done' : 'Close'),
        ),
      ],
    );
  }
}

// ─── YouTube Download Dialog ───────────────────────────────────
class _YouTubeDownloadDialog extends StatefulWidget {
  final String youtubeUrl;
  final VoidCallback onComplete;
  final ValueChanged<String> onError;

  const _YouTubeDownloadDialog({
    required this.youtubeUrl,
    required this.onComplete,
    required this.onError,
  });

  @override
  State<_YouTubeDownloadDialog> createState() =>
      _YouTubeDownloadDialogState();
}

class _YouTubeDownloadDialogState extends State<_YouTubeDownloadDialog> {
  late final String _downloadId;
  Timer? _pollTimer;
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _events = const [];
  Map<String, dynamic> _details = const {};

  String _stage = 'starting';
  double _progressValue = 0.0;
  String _message = 'Starting…';

  bool _finished = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _downloadId = DateTime.now().microsecondsSinceEpoch.toString();
    _startDownload();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _poll(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    try {
      final response = await http.post(
        Uri.parse('$flaskServerUrl/api/youtube-download-and-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': widget.youtubeUrl,
          'auto_segmentation': true,
          'download_id': _downloadId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          setState(() {
            _finished = true;
            _progressValue = 1.0;
            _stage = 'done';
          });
          widget.onComplete();
        } else {
          final msg = data['error']?.toString() ?? 'Unknown error';
          setState(() {
            _finished = true;
            _error = msg;
          });
          widget.onError(msg);
        }
      } else {
        final msg = 'Server error: ${response.statusCode}';
        setState(() {
          _finished = true;
          _error = msg;
        });
        widget.onError(msg);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finished = true;
        _error = 'Network error: $e';
      });
      widget.onError('Network error: $e');
    }
  }

  Future<void> _poll() async {
    if (!mounted) return;
    try {
      final resp = await http.get(
        Uri.parse('$flaskServerUrl/api/download-progress/$_downloadId'),
      );
      if (resp.statusCode != 200 || !mounted) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final newEvents =
          (data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      setState(() {
        _events = newEvents;
        _details = (data['details'] as Map?)?.cast<String, dynamic>() ?? {};
        _stage = data['stage']?.toString() ?? _stage;
        _progressValue =
            (data['progress'] as num?)?.toDouble() ?? _progressValue;
        _message = data['message']?.toString() ?? _message;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController
              .jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } catch (_) {
      // ignore transient polling errors
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = MediaQuery.of(context).size.width * 0.8;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _error != null
                ? Icons.error_outline
                : _finished
                    ? Icons.check_circle
                    : Icons.downloading,
            color: _error != null
                ? Colors.red
                : _finished
                    ? Colors.green
                    : Colors.blue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error != null
                  ? 'Import Failed'
                  : _finished
                      ? 'Import Complete'
                      : 'Downloading YouTube Video',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth.clamp(400, 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.youtubeUrl,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progressValue.clamp(0.0, 1.0),
              minHeight: 6,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _stage.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  '${(_progressValue * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_details.isNotEmpty) _buildInfoCard(),
            const SizedBox(height: 12),
            const Text(
              'Log',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Container(
              height: 220,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade700),
              ),
              padding: const EdgeInsets.all(8),
              child: _events.isEmpty
                  ? const Center(
                      child: Text(
                        'Waiting for server…',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _events.length,
                      itemBuilder: (ctx, i) {
                        final ev = _events[i];
                        final level = ev['level']?.toString() ?? 'info';
                        final time = ev['time']?.toString() ?? '';
                        final msg = ev['message']?.toString() ?? '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: Colors.white,
                                height: 1.35,
                              ),
                              children: [
                                TextSpan(
                                  text: '$time  ',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                TextSpan(
                                  text: _icon(level),
                                  style: TextStyle(color: _colorFor(level)),
                                ),
                                const TextSpan(text: ' '),
                                TextSpan(
                                  text: msg,
                                  style: TextStyle(color: _colorFor(level)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_finished || _error != null)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildInfoCard() {
    final rows = <Widget>[];

    void addRow(String label, String? value, {Color? color}) {
      if (value == null || value.isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ));
    }

    addRow('Title', _details['title']?.toString());
    addRow('Filename', _details['filename']?.toString());
    addRow('Duration',
        _details['duration'] != null ? '${_details['duration']} s' : null);
    addRow(
      'File size',
      _details['filesize'] != null
          ? _formatBytes((_details['filesize'] as num).toInt())
          : null,
    );
    addRow(
      'Audio',
      _details['has_audio'] == null
          ? null
          : (_details['has_audio'] == true ? '✅ present' : '❌ missing'),
      color: _details['has_audio'] == true ? Colors.green : Colors.red,
    );
    addRow('Codec', _details['codec']?.toString());
    if (_details['converted'] == true) {
      addRow('Converted', 'H.264 (browser compatible)',
          color: Colors.green);
    } else if (_details['converted'] == false) {
      addRow('Converted', 'Not needed', color: Colors.grey);
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  String _icon(String level) {
    switch (level) {
      case 'error':
        return '✗';
      case 'warning':
        return '⚠';
      default:
        return '›';
    }
  }

  Color _colorFor(String level) {
    switch (level) {
      case 'error':
        return const Color(0xFFFF6B6B);
      case 'warning':
        return const Color(0xFFFFC107);
      default:
        return const Color(0xFFB0BEC5);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}