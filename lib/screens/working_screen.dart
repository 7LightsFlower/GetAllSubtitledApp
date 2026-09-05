// working_screen.dart
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/screens/session_detail_screen.dart';
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
  });

  factory VideoProject.fromJson(Map<String, dynamic> json) {
    return VideoProject(
      key: json['key'] as String? ?? 'fallback-${DateTime.now().millisecondsSinceEpoch}',
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
  bool _isConnected = false;
  bool _isConnecting = false;
  String _searchQuery = '';
  String _sortMode = 'newest';
  double _storageUsed = 0.0;
  double _storageLimit = 50.0;
  String? _listError;

  // ─── Connection management ──────────────────────────────────────────────

  Future<void> _checkConnection() async {
    if (!mounted) return;
    final token = await InternalAuthService.getToken();
    if (mounted) {
      setState(() => _isConnected = token != null && token.isNotEmpty);
    }
  }

  Future<void> _connectToInternal() async {
    if (!mounted || _isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      final success = await InternalAuthService.loginWithOAuth();
      if (!mounted) return;
      if (success) {
        setState(() => _isConnected = true);
        _showSnackBar('✅ Connected to internal server.');
        _fetchProjects();
      } else {
        _showSnackBar('❌ Connection failed. Please try again.', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnackBar('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<String> _getToken() async {
    final token = await InternalAuthService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('No token. Use "Manual Token" or click "Connect".');
    }
    return token;
  }

  // ─── Manual token dialog ───────────────────────────────────────────────

  void _showManualTokenDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Cookie Token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste the token from /gettoken (e.g., "abc...|123|user@kit.edu")'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Paste token here',
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
            onPressed: () async {
              final token = controller.text.trim();
              if (token.isNotEmpty) {
                await InternalAuthService.setManualToken(token);
                if (mounted) {
                  setState(() => _isConnected = true);
                  _showSnackBar('✅ Token set manually.');
                  if (ctx.mounted) Navigator.pop(ctx);
                }
                _fetchProjects();
              }
            },
            child: const Text('Set Token'),
          ),
          TextButton(
            onPressed: () async {
              await InternalAuthService.clearManualToken();
              if (mounted) {
                setState(() => _isConnected = false);
                _showSnackBar('Manual token cleared.');
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Clear Token', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _checkConnection();
    _fetchProjects();
  }

  Future<void> _fetchProjects() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _listError = null;
    });

    try {
      final url = Uri.parse('$authBaseUrl/videos');
      if (kDebugMode) print('📡 Fetching videos from: $url');
      final response = await http.get(url, headers: {'Content-Type': 'application/json'});

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (kDebugMode) {
          print('📦 Video list response: ${jsonEncode(data)}');
        }

        final projects = (data['projects'] as List?)?.map((e) {
          try {
            return VideoProject.fromJson(e as Map<String, dynamic>);
          } catch (e) {
            if (kDebugMode) print('❌ Error parsing project: $e');
            return null;
          }
        }).whereType<VideoProject>().toList() ?? [];

        if (mounted) {
          setState(() {
            _projects = projects;
            _storageUsed = (data['storage_used_gb'] ?? 0.0).toDouble();
            _storageLimit = (data['storage_limit_gb'] ?? 50.0).toDouble();
            _isLoading = false;
          });
        }
      } else {
        throw Exception('Failed to load projects (HTTP ${response.statusCode})');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error in _fetchProjects: $e');
      if (mounted) {
        setState(() {
          _listError = 'Error loading projects: $e';
          _isLoading = false;
        });
      }
    }
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

  // ─── YouTube URL detection and extraction ─────────────────────────────

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

      // Use your server's YouTube API endpoint
      const serverUrl = 'http://localhost:5000/api/youtube-info';
      
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

  // Add this method to handle YouTube imports directly

  Future<void> _importYouTubeDirectly(String youtubeUrl) async {
    if (!mounted) return;
    
    try {
      final token = await InternalAuthService.getToken();
      if (token == null || token.isEmpty) {
        _showSnackBar('Please authenticate first.', isError: true);
        return;
      }

      if (!mounted) return;

      // Show downloading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          title: Text('Downloading YouTube Video'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Downloading and processing video...'),
            ],
          ),
        ),
      );

      // Call the server to download and upload
      const serverUrl = 'http://localhost:5000/api/youtube-download-and-upload';
      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'url': youtubeUrl,
          'auto_segmentation': true,
        }),
      );

      // Close the loading dialog
      if (mounted) Navigator.pop(context);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          _showSnackBar('✅ YouTube video downloaded and imported!');
          _fetchProjects();
        } else {
          _showSnackBar('❌ Error: ${data['error']}', isError: true);
        }
      } else {
        _showSnackBar('❌ Server error: ${response.statusCode}', isError: true);
      }

    } catch (e) {
      if (mounted) Navigator.pop(context);
      _showSnackBar('❌ Error: $e', isError: true);
    }
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


  // ─── Import from text ─────────────────────────────────────────────────

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
                    hintText: 'https://example.com/video1.mp4\nhttps://youtube.com/watch?v=abc123\nhttps://example.com/video2.mp4\n...',
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
    final urls = text.split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    
    if (urls.isEmpty) {
      _showSnackBar('No URLs found in text.', isError: true);
      return;
    }
    
    // Show import progress dialog
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

  Future<void> _importVideosFromUrls(List<String> urls, bool autoSegmentation) async {
    if (!mounted) return;
    
    // First, resolve YouTube URLs
    List<Map<String, String>> resolvedUrls = [];
    List<String> errors = [];
    
    for (final url in urls) {
      if (_isYouTubeUrl(url)) {
        // Try to get the actual video URL
        final videoUrl = await _getYouTubeVideoUrl(url);
        if (videoUrl != null) {
          resolvedUrls.add({
            'original': url,
            'resolved': videoUrl,
          });
          if (kDebugMode) print('✅ Resolved YouTube URL: $url -> $videoUrl');
        } else {
          errors.add('Could not resolve YouTube URL: $url');
          if (kDebugMode) print('❌ Failed to resolve YouTube URL: $url');
        }
      } else if (_isValidUrl(url)) {
        resolvedUrls.add({
          'original': url,
          'resolved': url,
        });
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
    
    // Extract resolved URLs
    final finalUrls = resolvedUrls.map((entry) => entry['resolved']!).toList();
    
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

  // ─── Navigation and actions ──────────────────────────────────

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
              leading: const Icon(Icons.stop_circle, color: Colors.orange),
              title: const Text('Stop Segmentation'),
              onTap: () {
                Navigator.pop(ctx);
                _stopSegmentation(project.key);
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
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Project', style: TextStyle(color: Colors.red)),
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

  // ─── Internal actions (require cookie token) ──────────────────────────

  Future<void> _stopSegmentation(String videoKey) async {
    if (!mounted) return;
    String token;
    try {
      token = await _getToken();
    } catch (e) {
      _showSnackBar('Cannot get token: $e', isError: true);
      return;
    }

    final confirm = await _confirmAction('Stop segmentation?');
    if (!confirm) return;
    try {
      final response = await http.post(
        Uri.parse('$internalServerUrl/stop_segmentation/$videoKey'),
        headers: {'Cookie': '_forward_auth=$token'},
      );
      if (mounted) {
        if (response.statusCode == 200) {
          _showSnackBar('Segmentation stopped.');
          _fetchProjects();
        } else {
          _showSnackBar('Failed to stop segmentation.', isError: true);
        }
      }
    } catch (e) {
      if (mounted) _showSnackBar('Error: $e', isError: true);
    }
  }

  void _showSegmentationSettings(String videoKey) {
    Navigator.pushNamed(context, '/segmentation', arguments: videoKey);
  }

  void _showSegmentsList(String videoKey) {
    Navigator.pushNamed(context, '/segments_list', arguments: videoKey);
  }

  Future<void> _deleteProject(String videoKey) async {
    if (!mounted) return;
    String token;
    try {
      token = await _getToken();
    } catch (e) {
      _showSnackBar('Cannot get token: $e', isError: true);
      return;
    }

    final confirm = await _confirmAction('Delete this project permanently? This cannot be undone.');
    if (!confirm) return;
    try {
      final response = await http.post(
        Uri.parse('$internalServerUrl/delete_video/$videoKey'),
        headers: {
          'Content-Type': 'application/json',
          'Cookie': '_forward_auth=$token',
        },
      );
      if (mounted) {
        if (response.statusCode == 200) {
          _showSnackBar('Project deleted.');
          _fetchProjects();
        } else {
          _showSnackBar('Failed to delete.', isError: true);
        }
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
    ) ?? false;
  }

  // ─── Edit name – uses internal API ──────────────────────────────────

  Future<void> _editProjectName(VideoProject project) async {
    if (!mounted) return;
    String token;
    try {
      token = await _getToken();
    } catch (e) {
      _showSnackBar('Cannot get token: $e', isError: true);
      return;
    }

    final controller = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      // ignore: use_build_context_synchronously
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
          Uri.parse('$internalServerUrl/update_project_name/${project.key}'),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': '_forward_auth=$token',
          },
          body: jsonEncode({'project_name': newName}),
        );
        if (mounted) {
          if (response.statusCode == 200) {
            _showSnackBar('Project name updated.');
            _fetchProjects();
          } else {
            _showSnackBar('Failed to update name.', isError: true);
          }
        }
      } catch (e) {
        if (mounted) _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  // ─── Upload – using bytes (web-compatible) ──────────────────────────

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
        onUploadComplete: _fetchProjects,
      ),
    );
  }

  // ─── Logout from public server ──────────────────────────────────────

  Future<void> _logoutPublic() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await InternalAuthService.clearTokens();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  // ─── UI Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appTitle),
        actions: [
          // ─── YouTube Import Button ────────────────────────────────────
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => _showYouTubeImportDialog(),
            tooltip: 'Download YouTube Video',
          ),
          // ─── Import from Text Button ────────────────────────────────────
          IconButton(
            icon: const Icon(Icons.text_snippet),
            onPressed: _importVideosFromText,
            tooltip: 'Import from text links',
          ),
          // ─── Manual Token Button ────────────────────────────────────
          IconButton(
            icon: const Icon(Icons.vpn_key),
            onPressed: _showManualTokenDialog,
            tooltip: 'Manual Token',
          ),
          IconButton(
            icon: Icon(_isConnected ? Icons.link : Icons.link_off),
            onPressed: _isConnecting ? null : _connectToInternal,
            tooltip: _isConnected ? 'Reconnect' : 'Connect',
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
                          DropdownMenuItem(value: 'newest', child: Text('Newest First')),
                          DropdownMenuItem(value: 'oldest', child: Text('Oldest First')),
                          DropdownMenuItem(value: 'last-opened', child: Text('Last Opened')),
                          DropdownMenuItem(value: 'az', child: Text('Name A → Z')),
                          DropdownMenuItem(value: 'za', child: Text('Name Z → A')),
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
                            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                          ),
                          Text(
                            '${_storageUsed.toStringAsFixed(2)} GB / $_storageLimit GB',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: _storageUsed / _storageLimit,
                        backgroundColor: Colors.grey[300],
                        valueColor: const AlwaysStoppedAnimation(Colors.blue),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _buildGrid(),
                ),
              ],
            ),
    );
  }

  Widget _buildGrid() {
    if (_listError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 60, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'Unable to load projects',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 8),
            Text(
              _listError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _fetchProjects,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
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
            Text('Upload a video to get started.', style: TextStyle(color: Colors.grey)),
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
      itemBuilder: (context, index) {
        final project = filtered[index];
        return _buildCard(project);
      },
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
            // ─── Thumbnail / Preview Image ──────────────────────────────
            Expanded(
              flex: 2,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                child: project.thumbnailUrl != null && project.thumbnailUrl!.isNotEmpty
                    ? Image.network(
                        project.thumbnailUrl!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildThumbnailPlaceholder(project);
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            color: Colors.grey[300],
                            child: Center(
                              child: CircularProgressIndicator(
                                value: loadingProgress.expectedTotalBytes != null
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
            // ─── Card Content ───────────────────────────────────────────
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(6.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Project Name
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
                    // File Name
                    Text(
                      project.fileName,
                      style: TextStyle(
                        fontSize: 9, 
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Duration and Segments
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
                    // Upload Date
                    Text(
                      _formatDate(project.uploaded),
                      style: TextStyle(
                        fontSize: 8, 
                        color: Colors.grey[400],
                      ),
                    ),
                    // Pipeline Status
                    _buildPipelineStatus(project),
                    const Spacer(),
                    // Work Button
                    Align(
                      alignment: Alignment.bottomRight,
                      child: ElevatedButton(
                        onPressed: () => _openSessionDetail(project.key),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          textStyle: const TextStyle(fontSize: 9),
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Open'),
                      ),
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

  // ─── Thumbnail Placeholder with Video Info ──────────────────────────
  
  Widget _buildThumbnailPlaceholder(VideoProject project) {
    return Container(
      color: Colors.grey[800],
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background gradient
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.grey[800]!,
                  Colors.grey[900]!,
                ],
              ),
            ),
          ),
          // Video icon and duration in center
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          // File format badge at bottom
          Positioned(
            bottom: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                project.fileName.split('.').last.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineStatus(VideoProject project) {
    if (project.segmentationDone) {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: 11),
          SizedBox(width: 2),
          Text('Done', style: TextStyle(fontSize: 8, color: Colors.green)),
        ],
      );
    } else if (project.segmentationProgress > 0) {
      return Row(
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: project.segmentationProgress / 100,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            '${project.segmentationProgress}%',
            style: const TextStyle(fontSize: 8),
          ),
        ],
      );
    } else {
      return const Row(
        children: [
          Icon(Icons.content_cut, color: Colors.grey, size: 11),
          SizedBox(width: 2),
          Text('Pending', style: TextStyle(fontSize: 8, color: Colors.grey)),
        ],
      );
    }
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
    } else {
      return '$bytes B';
    }
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
        final token = await InternalAuthService.getToken();
        if (token == null || token.isEmpty) {
          throw Exception('No authentication token available');
        }
        
        // Download video from URL
        final response = await http.get(
          Uri.parse(status.url),
          headers: {
            'Accept': 'video/*, application/octet-stream',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept-Encoding': 'identity', // Don't compress
          },
        );
        
        if (response.statusCode != 200) {
          throw Exception('Failed to download: HTTP ${response.statusCode}');
        }
        
        if (response.bodyBytes.isEmpty) {
          throw Exception('Downloaded file is empty');
        }
        
        // Extract filename from URL
        final fileName = _extractFileNameFromUrl(status.url, response);
        
        setState(() {
          status.message = 'Uploading...';
        });
        
        // Upload to server
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
    
    setState(() {
      _isComplete = true;
    });
    
    // Notify completion
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
      final end = (i + 1) * chunkSize > totalBytes ? totalBytes : (i + 1) * chunkSize;
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

    // Finish upload
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
    // Try to get filename from Content-Disposition header
    final disposition = response.headers['content-disposition'];
    if (disposition != null) {
      final regex = RegExp(r'filename="([^"]+)"');
      final match = regex.firstMatch(disposition);
      if (match != null) {
        return match.group(1)!;
      }
    }
    
    // Extract from URL path
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final segments = path.split('/');
      final lastSegment = segments.last;
      if (lastSegment.contains('.')) {
        return lastSegment;
      }
    } catch (_) {}
    
    // Generate filename
    final extension = _getFileExtensionFromUrl(url);
    return 'video_${DateTime.now().millisecondsSinceEpoch}.$extension';
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
                value: _statuses.isEmpty ? 0 : 
                    _statuses.where((s) => s.state == ImportState.completed).length / _statuses.length,
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
                        color: status.state == ImportState.error ? Colors.red : 
                               status.state == ImportState.completed ? Colors.green : 
                               Colors.grey,
                      ),
                    ),
                    subtitle: status.state == ImportState.downloading && status.progress > 0
                        ? LinearProgressIndicator(
                            value: status.progress / 100,
                            minHeight: 4,
                          )
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

// ─── Upload Dialog – accepts bytes (web-compatible) ──────────────

class _UploadDialog extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final VoidCallback onUploadComplete;

  const _UploadDialog({
    required this.bytes,
    required this.fileName,
    required this.onUploadComplete,
  });

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<_UploadDialog> {
  double _progress = 0.0;
  bool _isUploading = false;
  String _statusText = 'Ready';
  bool _autoSegmentation = true;

  @override
  void initState() {
    super.initState();
    _startUpload();
  }

  Future<void> _startUpload() async {
    setState(() {
      _isUploading = true;
      _statusText = 'Uploading...';
    });

    const chunkSize = 5 * 1024 * 1024;
    final totalBytes = widget.bytes.length;
    final totalChunks = (totalBytes / chunkSize).ceil();

    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize > totalBytes ? totalBytes : (i + 1) * chunkSize;
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

        setState(() {
          _progress = ((i + 1) / totalChunks) * 100;
          _statusText = 'Uploading ${_progress.toStringAsFixed(0)}%';
        });
      }

      // Finish upload
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

      setState(() {
        _statusText = 'Upload complete!';
        _isUploading = false;
      });

      widget.onUploadComplete();

      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          Navigator.pop(context, true);
        }
      });
    } catch (e) {
      setState(() {
        _statusText = 'Error: $e';
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  onChanged: (v) => setState(() => _autoSegmentation = v!),
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
}
