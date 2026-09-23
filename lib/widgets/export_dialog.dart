// widgets/export_dialog.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';

class ExportDialog extends StatefulWidget {
  final String sessionId;
  final List<String> languages;

  const ExportDialog({
    super.key,
    required this.sessionId,
    required this.languages,
  });

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  String _selectedFormat = 'txt';
  String _selectedLanguage = '';
  bool _isExporting = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    if (widget.languages.isNotEmpty) {
      _selectedLanguage = widget.languages.first;
    }
  }

  Future<void> _exportTranscript() async {
    if (_selectedLanguage.isEmpty) {
      setState(() {
        _statusMessage = 'Please select a language';
      });
      return;
    }

    setState(() {
      _isExporting = true;
      _statusMessage = 'Exporting...';
    });

    try {
      final token = await InternalAuthService.getToken();
      
      // Use the correct endpoints from the Flask server
      String exportUrl;
      if (_selectedFormat == 'docx') {
        exportUrl = '$flaskServerUrl/session-export-docx/${widget.sessionId}';
      } else if (_selectedFormat == 'txt') {
        exportUrl = '$flaskServerUrl/session-export-txt/${widget.sessionId}';
      } else if (_selectedFormat == 'rtf') {
        exportUrl = '$flaskServerUrl/session-export-rtf/${widget.sessionId}';
      } else if (_selectedFormat == 'json') {
        exportUrl = '$flaskServerUrl/session-export-structured-json/${widget.sessionId}';
      } else {
        exportUrl = '$flaskServerUrl/session-export-txt/${widget.sessionId}';
      }

      // Add language parameter
      final uri = Uri.parse(exportUrl).replace(queryParameters: {
        'language': _selectedLanguage,
      });

      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        if (_selectedFormat == 'json') {
          await _downloadJsonFile(response.body);
          return;
        }

        // Get filename from Content-Disposition header
        final contentDisposition = response.headers['content-disposition'] ?? '';
        
        // Try multiple patterns to extract filename
        String filename = 'transcript_${widget.sessionId}.$_selectedFormat';
        String? extractedFilename;

        // Pattern 1: filename="name.ext"
        final filenameMatch1 = RegExp(r'filename="([^"]+)"').firstMatch(contentDisposition);
        if (filenameMatch1 != null) {
          extractedFilename = filenameMatch1.group(1);
        }
        // Pattern 2: filename*=UTF-8''name.ext
        if (extractedFilename == null) {
          final filenameMatch2 = RegExp(r"filename\*=(?:UTF-8'')?([^;]+)").firstMatch(contentDisposition);
          if (filenameMatch2 != null) {
            extractedFilename = Uri.decodeComponent(filenameMatch2.group(1)!);
          }
        }
        // Pattern 3: filename='name.ext' (single quotes)
        if (extractedFilename == null) {
          final filenameMatch3 = RegExp(r"filename='([^']+)'").firstMatch(contentDisposition);
          if (filenameMatch3 != null) {
            extractedFilename = filenameMatch3.group(1);
          }
        }

        // If we found a filename in the header, use it
        if (extractedFilename != null && extractedFilename.isNotEmpty) {
          filename = extractedFilename;
        }

        String mimeType;
        if (_selectedFormat == 'docx') {
          mimeType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        } else if (_selectedFormat == 'txt') {
          mimeType = 'text/plain';
        } else if (_selectedFormat == 'rtf') {
          mimeType = 'application/rtf';
        } else {
          mimeType = 'application/json';
        }

        // Download the file using html package (web)
        final blob = html.Blob([response.bodyBytes], mimeType);
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', filename)
          ..click();
        html.Url.revokeObjectUrl(url);

        if (!mounted) return;
        
        setState(() {
          _isExporting = false;
          _statusMessage = '✅ Exported successfully: $filename';
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Download started!'),
              backgroundColor: Colors.green,
            ),
          );
        }

        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      } else {
        throw Exception('Export failed: ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _isExporting = false;
        _statusMessage = '❌ Error: $e';
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _downloadJsonFile(String jsonData) async {
    try {
      final data = jsonDecode(jsonData);
      final prettyJson = const JsonEncoder.withIndent('  ').convert(data);
      
      // Try to extract filename from the JSON or use a default
      String filename = 'transcript_${widget.sessionId}.json';
      
      const mimeType = 'application/json';
      
      final bytes = utf8.encode(prettyJson);
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();
      html.Url.revokeObjectUrl(url);
      
      if (mounted) {
        setState(() {
          _isExporting = false;
          _statusMessage = '✅ Exported successfully: $filename';
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Download started!'),
            backgroundColor: Colors.green,
          ),
        );
        
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _statusMessage = '❌ Error exporting JSON: $e';
        });
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export Transcript'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Language selection
            const Text(
              'Select Language:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: DropdownButtonFormField<String>(
                initialValue: _selectedLanguage.isNotEmpty ? _selectedLanguage : null,
                hint: const Text('Choose language'),
                isExpanded: true,
                items: widget.languages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang,
                    child: Text(
                      lang,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedLanguage = value ?? '';
                  });
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Format selection
            const Text(
              'Select Format:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFormatChip('txt', 'TXT'),
                _buildFormatChip('docx', 'DOCX'),
                _buildFormatChip('rtf', 'RTF'),
                _buildFormatChip('json', 'JSON'),
              ],
            ),
            const SizedBox(height: 16),

            // Status message
            if (_statusMessage.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _statusMessage.contains('✅') 
                      ? Colors.green[50] 
                      : _statusMessage.contains('❌') 
                          ? Colors.red[50] 
                          : Colors.grey[50],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _statusMessage.contains('✅') 
                        ? Colors.green 
                        : _statusMessage.contains('❌') 
                            ? Colors.red 
                            : Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isExporting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _isExporting ? null : _exportTranscript,
          icon: _isExporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(_isExporting ? 'Exporting...' : 'Export'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildFormatChip(String format, String label) {
    return FilterChip(
      label: Text(label),
      selected: _selectedFormat == format,
      onSelected: (selected) {
        setState(() {
          _selectedFormat = format;
        });
      },
      selectedColor: Colors.blue[100],
    );
  }
}
