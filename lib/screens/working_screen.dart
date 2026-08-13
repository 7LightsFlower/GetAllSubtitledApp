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

  @override
  void initState() {
    super.initState();
    _fetchProjects();
  }

  Future<void> _fetchProjects() async {
    setState(() {
      _isLoading = true;
      _listError = null;
    });

    try {
      final url = Uri.parse('$authBaseUrl/videos');
      if (kDebugMode) print('📡 Fetching videos from: $url');
      final response = await http.get(url, headers: {'Content-Type': 'application/json'});

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

        setState(() {
          _projects = projects;
          _storageUsed = (data['storage_used_gb'] ?? 0.0).toDouble();
          _storageLimit = (data['storage_limit_gb'] ?? 50.0).toDouble();
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load projects (HTTP ${response.statusCode})');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error in _fetchProjects: $e');
      setState(() {
        _listError = 'Error loading projects: $e';
        _isLoading = false;
      });
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

  // ─── Token display helpers ──────────────────────────────────────────

  void _showTokenDialog(String token, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(
          token,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          maxLines: 10,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Token copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCurrentToken() async {
    final token = await InternalAuthService.getValidAccessToken();
    if (token == null) {
      _showSnackBar('No token available. Please log in first.', isError: true);
      return;
    }
    _showTokenDialog(token, 'Current Access Token');
  }

  // ─── OAuth2 actions ─────────────────────────────────────────────────

  Future<void> _showOAuthLogin() async {
    final success = await InternalAuthService.loginWithOAuth();
    if (success && mounted) {
      _showSnackBar('Internal server connected via OAuth.');
      final token = await InternalAuthService.getValidAccessToken();
      if (token != null) {
        _showTokenDialog(token, 'Token obtained from OAuth');
      }
    } else if (mounted) {
      _showSnackBar('OAuth login failed. Please try again.', isError: true);
    }
  }

  Future<void> _logoutInternal() async {
    await InternalAuthService.clearTokens();
    if (mounted) {
      _showSnackBar('Internal server disconnected.');
    }
  }

  // ─── Redirect login (full‑page redirect) ────────────────────────────

  Future<void> _loginWithRedirect() async {
    try {
      await InternalAuthService.redirectToDex();
    } catch (e) {
      _showSnackBar('Redirect error: $e', isError: true);
    }
  }

  // ─── Manual code exchange (debug workaround) – FIXED ───────────────

  void _showManualCodeDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manual Code Exchange'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste the code from the redirect URL after login:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Code',
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
              final code = controller.text.trim();
              if (code.isEmpty) {
                // Use the dialog's context for the snackbar
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Please enter a code')),
                );
                return;
              }

              // Perform the exchange
              final success = await InternalAuthService.exchangeCodeManually(code);

              // Guard: check both widget and dialog contexts
              if (!mounted) return;
              if (!ctx.mounted) return;

              if (success) {
                _showSnackBar('Token obtained successfully!');
                final token = await InternalAuthService.getValidAccessToken();
                if (token != null) {
                  _showTokenDialog(token, 'Token from manual exchange');
                }
              } else {
                _showSnackBar('Exchange failed. Check console.', isError: true);
              }

              // Close the dialog – ensure the context is still valid
              if (ctx.mounted) {
                Navigator.pop(ctx);
              }
            },
            child: const Text('Exchange'),
          ),
        ],
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

  // ─── Internal actions (require token) ──────────────────────────────

  Future<void> _stopSegmentation(String videoKey) async {
    final token = await InternalAuthService.getValidAccessToken();
    if (token == null) {
      _showSnackBar('Authentication required. Log in via Internal OAuth.', isError: true);
      return;
    }

    final confirm = await _confirmAction('Stop segmentation?');
    if (!confirm) return;
    try {
      await http.post(
        Uri.parse('$internalServerUrl/stop_segmentation/$videoKey'),
        headers: {'Authorization': 'Bearer $token'},
      );
      _fetchProjects();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _showSegmentationSettings(String videoKey) {
    Navigator.pushNamed(context, '/segmentation', arguments: videoKey);
  }

  void _showSegmentsList(String videoKey) {
    Navigator.pushNamed(context, '/segments_list', arguments: videoKey);
  }

  Future<void> _deleteProject(String videoKey) async {
    final token = await InternalAuthService.getValidAccessToken();
    if (token == null) {
      _showSnackBar('Authentication required. Log in via Internal OAuth.', isError: true);
      return;
    }

    final confirm = await _confirmAction('Delete this project permanently? This cannot be undone.');
    if (!confirm) return;
    try {
      final response = await http.post(
        Uri.parse('$internalServerUrl/delete_video/$videoKey'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (response.statusCode == 200) {
        _showSnackBar('Project deleted.');
        _fetchProjects();
      } else {
        _showSnackBar('Failed to delete.', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
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
    final token = await InternalAuthService.getValidAccessToken();
    if (token == null) {
      _showSnackBar('Authentication required. Log in via Internal OAuth.', isError: true);
      return;
    }

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
          Uri.parse('$internalServerUrl/update_project_name/${project.key}'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'project_name': newName}),
        );
        if (response.statusCode == 200) {
          _showSnackBar('Project name updated.');
          _fetchProjects();
        } else {
          _showSnackBar('Failed to update name.', isError: true);
        }
      } catch (e) {
        _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  // ─── Upload – using bytes (web-compatible) ──────────────────────────

  Future<void> _uploadVideo() async {
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

    if (!mounted) return;
    showDialog(
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await InternalAuthService.clearTokens();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  // ─── UI Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appTitle),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings),
            onSelected: (value) {
              if (value == 'oauth_login') {
                _showOAuthLogin();
              } else if (value == 'oauth_logout') {
                _logoutInternal();
              } else if (value == 'manual_code') {
                _showManualCodeDialog();
              } else if (value == 'redirect_login') {
                _loginWithRedirect();
              } else if (value == 'show_token') {
                _showCurrentToken();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'redirect_login',
                child: Text('Login with Redirect (Dex)'),
              ),
              const PopupMenuItem(
                value: 'oauth_login',
                child: Text('Internal OAuth Login (popup)'),
              ),
              const PopupMenuItem(
                value: 'oauth_logout',
                child: Text('Internal Logout'),
              ),
              const PopupMenuItem(
                value: 'manual_code',
                child: Text('Manual Code Exchange (debug)'),
              ),
              const PopupMenuItem(
                value: 'show_token',
                child: Text('Show Token'),
              ),
            ],
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
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                child: project.thumbnailUrl != null
                    ? Image.network(
                        project.thumbnailUrl!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) => _placeholderThumbnail(),
                      )
                    : _placeholderThumbnail(),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => _editProjectName(project),
                      child: Text(
                        project.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      project.fileName,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatDate(project.uploaded),
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                    Text(
                      'Segments: ${project.segmentCount}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                    _buildPipelineStatus(project),
                    if (project.languages.isNotEmpty)
                      Wrap(
                        spacing: 4,
                        children: project.languages.take(3).map((lang) {
                          return Chip(
                            label: Text(lang, style: const TextStyle(fontSize: 10)),
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          );
                        }).toList(),
                      ),
                    const Spacer(),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: ElevatedButton(
                        onPressed: () => _openSessionDetail(project.key),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Work'),
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

  Widget _placeholderThumbnail() {
    return Container(
      color: Colors.grey[300],
      child: const Icon(Icons.videocam, size: 50, color: Colors.grey),
    );
  }

  Widget _buildPipelineStatus(VideoProject project) {
    if (project.segmentationDone) {
      return const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: 14),
          SizedBox(width: 4),
          Text('Segmentation: Done', style: TextStyle(fontSize: 11)),
        ],
      );
    } else if (project.segmentationProgress > 0) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 4),
          Text(
            'Segmentation: ${project.segmentationProgress}%',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      );
    } else {
      return const Row(
        children: [
          Icon(Icons.content_cut, color: Colors.grey, size: 14),
          SizedBox(width: 4),
          Text('Segmentation: Not started', style: TextStyle(fontSize: 11)),
        ],
      );
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
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
