// session_output_screen.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';  // Add this import

class SessionOutputScreen extends StatefulWidget {
  final String sessionId;
  final String sessionUrl;

  const SessionOutputScreen({
    super.key,
    required this.sessionId,
    required this.sessionUrl,
  });

  @override
  State<SessionOutputScreen> createState() => _SessionOutputScreenState();
}

class _SessionOutputScreenState extends State<SessionOutputScreen> {
  List<Map<String, dynamic>> _files = [];
  bool _isLoading = true;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchSessionOutput();
  }

  Future<void> _fetchSessionOutput() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final url = '$flaskServerUrl/session_output/${widget.sessionId}';
      final token = await InternalAuthService.getToken();
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _files = List<Map<String, dynamic>>.from(data['files'] ?? []);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to load session output: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  void _downloadFile(String url, String filename) {
    html.window.open(url, '_blank');
  }

  void _downloadAllFiles() {
    final downloadUrl = '$flaskServerUrl/session_zip/${widget.sessionId}';
    html.window.open(downloadUrl, '_blank');
  }

  void _openSessionInBrowser() {
    html.window.open(widget.sessionUrl, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Output'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _files.isNotEmpty ? _downloadAllFiles : null,
            tooltip: 'Download All Files',
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: _openSessionInBrowser,
            tooltip: 'Open in Browser',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchSessionOutput,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_errorMessage),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _fetchSessionOutput,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Info card
                    Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green[200]!),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '✅ Session ID: ${widget.sessionId}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                                Text(
                                  'Total Files: ${_files.length}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _openSessionInBrowser,
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('Open'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // File list
                    Expanded(
                      child: _files.isEmpty
                          ? const Center(
                              child: Text('No files available'),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: _files.length,
                              itemBuilder: (context, index) {
                                final file = _files[index];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    leading: _getFileIcon(file['name']),
                                    title: Text(file['name']),
                                    subtitle: Text(
                                      _formatFileSize(file['size'] ?? 0),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.download),
                                      onPressed: () {
                                        final url = '$flaskServerUrl/session_file/${widget.sessionId}/${file['name']}';
                                        _downloadFile(url, file['name']);
                                      },
                                      tooltip: 'Download',
                                    ),
                                    onTap: () {
                                      final url = '$flaskServerUrl/session_file/${widget.sessionId}/${file['name']}';
                                      _downloadFile(url, file['name']);
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _getFileIcon(String filename) {
    if (filename.endsWith('.mp4') || filename.endsWith('.webm')) {
      return const Icon(Icons.video_file, color: Colors.blue);
    } else if (filename.endsWith('.wav') || filename.endsWith('.mp3')) {
      return const Icon(Icons.audio_file, color: Colors.green);
    } else if (filename.endsWith('.vtt') || filename.endsWith('.srt')) {
      return const Icon(Icons.subtitles, color: Colors.orange);
    } else if (filename.endsWith('.html') || filename.endsWith('.htm')) {
      return const Icon(Icons.html, color: Colors.purple);
    } else if (filename.endsWith('.zip')) {
      return const Icon(Icons.folder_zip, color: Colors.brown);
    } else if (filename.endsWith('.json')) {
      return const Icon(Icons.code, color: Colors.teal);
    } else {
      return const Icon(Icons.insert_drive_file, color: Colors.grey);
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
