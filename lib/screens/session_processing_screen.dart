// session_processing_screen.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/screens/session_output_screen.dart';

class SessionProcessingScreen extends StatefulWidget {
  final String sessionId;
  final String sessionUrl;
  final String videoName;

  const SessionProcessingScreen({
    super.key,
    required this.sessionId,
    required this.sessionUrl,
    required this.videoName,
  });

  @override
  State<SessionProcessingScreen> createState() => _SessionProcessingScreenState();
}

class _SessionProcessingScreenState extends State<SessionProcessingScreen> {
  bool _isChecking = false;
  String _statusMessage = '';
  int _checkCount = 0;
  bool _isComplete = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _startProcessing();
  }

  void _startProcessing() {
    setState(() {
      _statusMessage = '⏳ Video uploaded. Processing has started...\n'
                       'This may take several minutes depending on the video length.\n'
                       'Click "Check Output" when you want to see the results.';
      _checkCount = 0;
    });
  }

  Future<void> _checkOutput() async {
    if (_isChecking) return;

    setState(() {
      _isChecking = true;
      _statusMessage = '🔄 Checking for output...';
      _errorMessage = '';
    });

    try {
      final token = await InternalAuthService.getToken();
      final url = '$flaskServerUrl/session_output/${widget.sessionId}';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        if (totalFiles > 0) {
          // Files are ready!
          setState(() {
            _isChecking = false;
            _isComplete = true;
            _statusMessage = '✅ Output is ready! Found $totalFiles files.\n'
                             'Click "View Output" to see the results.';
          });
        } else {
          // No files yet - still processing
          _checkCount++;
          setState(() {
            _isChecking = false;
            _statusMessage = '⏳ Still processing... (Checked $_checkCount times)\n'
                             'The video is being processed. Please wait a few more minutes.\n'
                             'Click "Check Output" again to check progress.';
          });
        }
      } else {
        setState(() {
          _isChecking = false;
          _errorMessage = 'Failed to check output: ${response.statusCode}';
          _statusMessage = '❌ Error checking output. Please try again.';
        });
      }
    } catch (e) {
      setState(() {
        _isChecking = false;
        _errorMessage = 'Error: $e';
        _statusMessage = '❌ Error checking output. Please try again.';
      });
    }
  }

  void _viewOutput() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SessionOutputScreen(
          sessionId: widget.sessionId,
          sessionUrl: widget.sessionUrl,
        ),
      ),
    );
  }

  void _openSessionInBrowser() {
    html.window.open(widget.sessionUrl, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Processing Session'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: _openSessionInBrowser,
            tooltip: 'Open in Browser',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon
            Icon(
              _isComplete ? Icons.check_circle_outline : Icons.hourglass_empty,
              size: 80,
              color: _isComplete ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 24),

            // Title
            Text(
              _isComplete ? 'Processing Complete!' : 'Processing Video',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // Session ID
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Session ID:',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                  Text(
                    widget.sessionId,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Video Name
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Video:',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                  Text(
                    widget.videoName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Status Message
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Text(
                _statusMessage,
                style: const TextStyle(fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),

            if (_errorMessage.isNotEmpty)
              Text(
                _errorMessage,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            const SizedBox(height: 24),

            // Buttons
            Column(
              children: [
                if (!_isComplete) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isChecking ? null : _checkOutput,
                      icon: _isChecking
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
                        _isChecking ? 'Checking...' : 'Check Output',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Tip: Processing time depends on video length. '
                    'A 10-minute video may take 2-5 minutes to process.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],

                if (_isComplete) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _viewOutput,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('View Output'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: _checkOutput,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check Again'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}