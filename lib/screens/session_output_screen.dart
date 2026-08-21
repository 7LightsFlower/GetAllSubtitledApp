// session_output_screen.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';

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
  List<String> _availableLanguages = [];
  bool _isLoading = true;
  bool _isLoadingLanguages = false;
  String _errorMessage = '';
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _fetchSessionOutput();
    _fetchAvailableLanguages();
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

  Future<void> _fetchAvailableLanguages() async {
    setState(() => _isLoadingLanguages = true);
    
    try {
      final url = '$flaskServerUrl/session_languages/${widget.sessionId}';
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
          _availableLanguages = List<String>.from(data['languages'] ?? []);
          _isLoadingLanguages = false;
        });
      } else {
        setState(() => _isLoadingLanguages = false);
      }
    } catch (e) {
      setState(() => _isLoadingLanguages = false);
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

  // ─── EXPORT FUNCTIONS ──────────────────────────────────────────────
  
  void _exportSingleLanguage(String format, String language) {
    setState(() => _isExporting = true);
    final encodedLang = Uri.encodeComponent(language);
    final exportUrl = '$flaskServerUrl/session_export_${format.toLowerCase()}/${widget.sessionId}?language=$encodedLang';
    html.window.open(exportUrl, '_blank');
    setState(() => _isExporting = false);
  }

  void _exportAllLanguages(String format) {
    setState(() => _isExporting = true);
    final exportUrl = '$flaskServerUrl/session_export_all_languages/${widget.sessionId}?format=${format.toLowerCase()}';
    html.window.open(exportUrl, '_blank');
    setState(() => _isExporting = false);
  }

  void _showLanguageSelectionDialog(String format, String formatName) {
    if (_availableLanguages.isEmpty) {
      // If no languages detected, just export all
      _exportAllLanguages(format);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(_getFormatIcon(format), color: _getFormatColor(format)),
            const SizedBox(width: 8),
            Text('Export $formatName'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select language to export:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // "All Languages" option
                  _buildLanguageChip(
                    label: '📦 All Languages',
                    onTap: () {
                      Navigator.pop(context);
                      _exportAllLanguages(format);
                    },
                    isAllOption: true,
                  ),
                  // Individual languages
                  ..._availableLanguages.map((lang) => _buildLanguageChip(
                    label: lang,
                    onTap: () {
                      Navigator.pop(context);
                      _exportSingleLanguage(format, lang);
                    },
                    isAllOption: false,
                  )),
                ],
              ),
            ),
            if (_isLoadingLanguages)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageChip({
    required String label,
    required VoidCallback onTap,
    bool isAllOption = false,
  }) {
    return ActionChip(
      label: Text(label),
      onPressed: _isExporting ? null : onTap,
      backgroundColor: isAllOption 
          ? Colors.purple.withValues(alpha: 0.1)
          : Colors.blue.withValues(alpha: 0.1),
      side: BorderSide(
        color: isAllOption 
            ? Colors.purple.withValues(alpha: 0.3)
            : Colors.blue.withValues(alpha: 0.3),
      ),
    );
  }

  IconData _getFormatIcon(String format) {
    switch (format.toLowerCase()) {
      case 'txt': return Icons.text_snippet;
      case 'rtf': return Icons.description;
      case 'docx': return Icons.file_present;
      default: return Icons.file_download;
    }
  }

  Color _getFormatColor(String format) {
    switch (format.toLowerCase()) {
      case 'txt': return Colors.grey;
      case 'rtf': return Colors.orange;
      case 'docx': return Colors.blue;
      default: return Colors.purple;
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.file_download, color: Colors.blue),
            SizedBox(width: 8),
            Text('Export Session'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose export format:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildExportButton(
              icon: Icons.text_snippet,
              label: 'TXT',
              subtitle: 'Plain text format',
              color: Colors.grey,
              onPressed: () {
                Navigator.pop(context);
                _showLanguageSelectionDialog('txt', 'TXT');
              },
            ),
            const SizedBox(height: 8),
            _buildExportButton(
              icon: Icons.description,
              label: 'RTF',
              subtitle: 'Rich Text Format',
              color: Colors.orange,
              onPressed: () {
                Navigator.pop(context);
                _showLanguageSelectionDialog('rtf', 'RTF');
              },
            ),
            const SizedBox(height: 8),
            _buildExportButton(
              icon: Icons.file_present,
              label: 'DOCX',
              subtitle: 'Microsoft Word format',
              color: Colors.blue,
              onPressed: () {
                Navigator.pop(context);
                _showLanguageSelectionDialog('docx', 'DOCX');
              },
            ),
            const Divider(height: 24),
            _buildExportButton(
              icon: Icons.folder_zip,
              label: 'All Formats + All Languages',
              subtitle: 'Export everything as ZIP',
              color: Colors.purple,
              onPressed: () {
                Navigator.pop(context);
                _exportAllLanguages('zip');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildExportButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: Icon(icon, color: color),
        label: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            if (_isExporting)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
          ],
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        onPressed: _isExporting ? null : onPressed,
      ),
    );
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
            icon: const Icon(Icons.file_download),
            onPressed: _showExportDialog,
            tooltip: 'Export Session',
          ),
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
                    // Info card with export buttons
                    Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green[200]!),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
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
                            ],
                          ),
                          const SizedBox(height: 12),
                          // ─── EXPORT BUTTONS ROW ──────────────────
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _buildExportChip(
                                label: 'TXT',
                                icon: Icons.text_snippet,
                                color: Colors.grey,
                                onTap: () => _showLanguageSelectionDialog('txt', 'TXT'),
                              ),
                              _buildExportChip(
                                label: 'RTF',
                                icon: Icons.description,
                                color: Colors.orange,
                                onTap: () => _showLanguageSelectionDialog('rtf', 'RTF'),
                              ),
                              _buildExportChip(
                                label: 'DOCX',
                                icon: Icons.file_present,
                                color: Colors.blue,
                                onTap: () => _showLanguageSelectionDialog('docx', 'DOCX'),
                              ),
                              _buildExportChip(
                                label: 'All Files (ZIP)',
                                icon: Icons.folder_zip,
                                color: Colors.purple,
                                onTap: _downloadAllFiles,
                              ),
                              _buildExportChip(
                                label: 'Open Session',
                                icon: Icons.open_in_new,
                                color: Colors.green,
                                onTap: _openSessionInBrowser,
                              ),
                              if (_availableLanguages.isNotEmpty)
                                _buildExportChip(
                                  label: '📚 ${_availableLanguages.length} Languages',
                                  icon: Icons.translate,
                                  color: Colors.teal,
                                  onTap: _showExportDialog,
                                ),
                            ],
                          ),
                          // ─── LANGUAGE INDICATOR ───────────────────
                          if (_availableLanguages.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: _availableLanguages.map((lang) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.blue[100],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  lang,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue[800],
                                  ),
                                ),
                              )).toList(),
                            ),
                          ],
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

  Widget _buildExportChip({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      label: Text(label),
      avatar: Icon(icon, size: 16, color: color),
      onPressed: _isExporting ? null : onTap,
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
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
    } else if (filename.endsWith('.rtf')) {
      return const Icon(Icons.description, color: Colors.orange);
    } else if (filename.endsWith('.docx') || filename.endsWith('.doc')) {
      return const Icon(Icons.file_present, color: Colors.blue);
    } else if (filename.endsWith('.txt')) {
      return const Icon(Icons.text_snippet, color: Colors.grey);
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
