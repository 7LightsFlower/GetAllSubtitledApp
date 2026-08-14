// job_configuration_screen.dart
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:asr_live_translator/screens/live_output_screen.dart';

class JobConfigurationScreen extends StatefulWidget {
  final String videoKey;
  final String videoName;

  const JobConfigurationScreen({
    super.key,
    required this.videoKey,
    required this.videoName,
  });

  @override
  State<JobConfigurationScreen> createState() => _JobConfigurationScreenState();
}

class _JobConfigurationScreenState extends State<JobConfigurationScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sessionNameController;
  final TextEditingController _topicNameController = TextEditingController();
  final TextEditingController _speakerNameController = TextEditingController();
  final TextEditingController _shortenController = TextEditingController();
  final TextEditingController _muteController = TextEditingController(text: '120');
  final TextEditingController _pauseController = TextEditingController(text: '2');

  String _date = '';

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

  // Manual token state
  bool _showTokenInput = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

  // Response display state
  String _responseMessage = '';
  String _responseHtml = '';
  String _sessionUrl = '';
  String _sessionId = '';
  bool _showResponse = false;

  // --- Constants ---
  static const List<String> _allInputLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'nl', 'pl', 'tr', 'uk', 'vi', 'th', 'id', 'ms'
  ];
  static const List<String> _allOutputLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'nl', 'pl', 'tr', 'uk', 'vi', 'th'
  ];
  static const List<String> _allAudioLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'pl', 'tr', 'uk', 'vi', 'th'
  ];
  static const List<String> _availabilityOptions = [
    'private', 'private+qr', 'kitemployee', 'kitall', 'public'
  ];
  static const List<String> _formatOptions = [
    'mixed', 'resending', 'online', 'offline'
  ];
  static const List<String> _chapteringOptions = [
    'online_dynamic', 'online_static', 'offline', 'streaming_simple'
  ];
  static const List<String> _ttsQualityOptions = ['low_latency', 'high_quality'];
  static const List<String> _errorCorrectionOptions = ['None', 'dialog', 'dialog2'];
  static const List<String> _postproductionOptions = ['50', '70', '90'];

  // --- Init ---
  @override
  void initState() {
    super.initState();
    _sessionNameController = TextEditingController(text: _getDefaultSessionName());
    final now = DateTime.now();
    _date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _topicNameController.text = _sessionNameController.text;
    _checkConnection();
  }

  @override
  void dispose() {
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
    final dateTimeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return '${widget.videoName} – $dateTimeStr';
  }

  // --- Connection ---
  Future<void> _checkConnection() async {
    final token = await InternalAuthService.getToken();
    if (mounted) {
      setState(() => _isConnected = token != null && token.isNotEmpty);
    }
  }

  Future<void> _connectToInternal() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      final success = await InternalAuthService.loginWithOAuth();
      if (success && mounted) {
        setState(() => _isConnected = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Connected to internal server!')),
          );
        }
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
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  // --- Manual token ---
  Future<void> _setManualToken() async {
    final token = _tokenController.text.trim();
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

  Future<String> _getToken() async {
    final token = await InternalAuthService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Not connected to internal server. Please click "Connect" or set a manual token first.');
    }
    return token;
  }

  // --- Submit ---
  Future<void> _submitJob() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSubmitting = true);

    try {
      final token = await _getToken();
      if (kDebugMode) print('🚀 [UPLOAD] Using token: $token');

      const userEmail = 'admin@example.com';

      final localMediaUrl = Uri.parse('$authBaseUrl/media/${widget.videoKey}');
      if (kDebugMode) print('🌐 [DEBUG] Fetching video from local server: $localMediaUrl');

      http.Response localResponse = await http.get(localMediaUrl);
      if (localResponse.statusCode != 200) {
        final fallbackUrl = Uri.parse('$authBaseUrl/videos/${widget.videoKey}/download');
        final fallbackResponse = await http.get(fallbackUrl);
        if (fallbackResponse.statusCode != 200) {
          throw Exception(
            'Failed to fetch video from local server (HTTP ${fallbackResponse.statusCode}). '
            'Body: ${fallbackResponse.body}'
          );
        }
        localResponse = fallbackResponse;
      }

      final videoBytes = localResponse.bodyBytes;
      if (videoBytes.isEmpty) {
        throw Exception('Video file is empty.');
      }

      if (kDebugMode) print('✅ [DEBUG] Video fetched from local: ${videoBytes.length} bytes');

      await _uploadToInternalServer(
        videoBytes: videoBytes,
        fileName: widget.videoName,
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

  // --- Upload helper ---
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
    if (distinguishUnknownSpeakers) formData.append('distinguish_unknown_speakers', '1');

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
    formData.appendBlob('videofile', blob, fileName);

    final request = html.HttpRequest();
    request.open('POST', uploadUrl);
    request.send(formData);
    await request.onLoadEnd.first;

    final status = request.status ?? 0;
    final responseText = request.responseText;
    final finalUrl = request.responseUrl;

    if (status >= 200 && status < 300) {
      // Store the response for display
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
            _showResponse = true;
          });
        } catch (_) {
          setState(() {
            _responseMessage = responseText ?? 'Upload successful!';
            _showResponse = true;
          });
        }
      }

      // Check for session ID in redirect URL
      if (finalUrl != null && finalUrl.contains('/archivesession/')) {
        final sessionId = finalUrl.split('/archivesession/')[-1].split('/')[0];
        if (mounted) {
          setState(() {
            _sessionId = sessionId;
            _sessionUrl = finalUrl;
          });
          // Show response for a moment before navigating
          await Future.delayed(const Duration(seconds: 3));
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => LiveOutputScreen(
                  videoKey: widget.videoKey,
                  jobId: sessionId,
                ),
              ),
            );
          }
        }
        return;
      }

      // Check for session ID in JSON response
      try {
        final data = jsonDecode(responseText ?? '');
        if (data['session_id'] != null) {
          final sessionId = data['session_id'].toString();
          if (mounted) {
            setState(() {
              _sessionId = sessionId;
              _sessionUrl = data['session_url'] ?? '';
            });
            // Show response for a moment before navigating
            await Future.delayed(const Duration(seconds: 3));
            if (mounted) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => LiveOutputScreen(
                    videoKey: widget.videoKey,
                    jobId: sessionId,
                  ),
                ),
              );
            }
          }
          return;
        }
      } catch (_) {}

      // If no session ID, just show the response and stay on this screen
      return;
    } else {
      // Handle error
      String errorMsg = 'Upload failed (HTTP $status)';
      try {
        final errorBody = jsonDecode(responseText ?? '{}');
        errorMsg = errorBody['error'] ?? errorBody['message'] ?? errorMsg;
      } catch (_) {}
      
      if (mounted) {
        setState(() {
          _responseMessage = '❌ Error: $errorMsg';
          _showResponse = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMsg), backgroundColor: Colors.red),
        );
      }
      throw Exception('Upload failed (HTTP $status): $responseText');
    }
  }

  // --- Response display widget ---
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
          
          // Session link if available
          if (_sessionUrl.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '📎 Session Link:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      // Open in new tab
                      html.window.open(_sessionUrl, '_blank');
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
            const SizedBox(height: 8),
          ],
          
          // HTML content if available - show as formatted text with tap to view full
          if (_responseHtml.isNotEmpty) ...[
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
                    'Server Response:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  // Show first 500 characters of the HTML (stripped of tags)
                  Text(
                    _stripHtmlTags(_responseHtml),
                    style: const TextStyle(fontSize: 14),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      _showFullResponseDialog();
                    },
                    icon: const Icon(Icons.open_in_full),
                    label: const Text('View Full Response'),
                  ),
                ],
              ),
            ),
          ] else if (_responseMessage.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Text(
                _responseMessage,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
          
          // Action buttons
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
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
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showResponse = false;
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[300],
                  foregroundColor: Colors.black,
                ),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Helper method to strip HTML tags
  String _stripHtmlTags(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // Show full response in a dialog
  void _showFullResponseDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Full Server Response'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show session link if available
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                // Show the full HTML response
                const Text(
                  'Response HTML:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SelectableText(
                    _responseHtml.isNotEmpty ? _responseHtml : _responseMessage,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
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

  // --- Widget helpers ---
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

  // --- Build ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configure Job'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
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
              const Text('Input Languages', style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                children: _allInputLanguages.map((lang) {
                  return FilterChip(
                    label: Text(lang.toUpperCase()),
                    selected: _inputLanguages.contains(lang),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _inputLanguages.add(lang);
                        } else {
                          _inputLanguages.remove(lang);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Output Languages
              const Text('Output Languages (Translation)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                children: _allOutputLanguages.map((lang) {
                  return FilterChip(
                    label: Text(lang.toUpperCase()),
                    selected: _outputLanguages.contains(lang),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _outputLanguages.add(lang);
                        } else {
                          _outputLanguages.remove(lang);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Audio Languages
              const Text('Generated Audio Languages',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                children: _allAudioLanguages.map((lang) {
                  return FilterChip(
                    label: Text(lang.toUpperCase()),
                    selected: _audioLanguages.contains(lang),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _audioLanguages.add(lang);
                        } else {
                          _audioLanguages.remove(lang);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Availability
              _buildDropdownField<String>(
                label: 'Availability',
                value: _availability,
                options: _availabilityOptions,
                onChanged: (val) => setState(() => _availability = val!),
              ),
              const SizedBox(height: 16),

              // Format
              _buildDropdownField<String>(
                label: 'Presentation Format',
                value: _format,
                options: _formatOptions,
                onChanged: (val) => setState(() => _format = val!),
              ),
              const SizedBox(height: 16),

              // Smart Chaptering
              _buildDropdownField<String>(
                label: 'Smart Chaptering',
                value: _smartChaptering,
                options: _chapteringOptions,
                onChanged: (val) => setState(() => _smartChaptering = val!),
              ),
              const SizedBox(height: 16),

              // TTS Quality Mode
              _buildDropdownField<String>(
                label: 'TTS Quality Mode',
                value: _ttsQualityMode,
                options: _ttsQualityOptions,
                onChanged: (val) => setState(() => _ttsQualityMode = val!),
              ),
              const SizedBox(height: 16),

              // Error Correction
              _buildDropdownField<String>(
                label: 'Error Correction',
                value: _errorCorrection,
                options: _errorCorrectionOptions,
                onChanged: (val) => setState(() => _errorCorrection = val!),
              ),
              const SizedBox(height: 16),

              // Post-production (multi-select)
              _buildMultiSelectChips(
                label: 'Shortening (Post-production)',
                selected: _postproduction,
                allOptions: _postproductionOptions,
                onChanged: (newList) => setState(() => _postproduction..clear()..addAll(newList)),
              ),
              const SizedBox(height: 16),

              // Permanent Name
              TextFormField(
                controller: _shortenController,
                decoration: const InputDecoration(
                  labelText: 'Permanent Name (alphanumeric only)',
                  border: OutlineInputBorder(),
                  hintText: 'Leave empty for random',
                ),
                validator: (val) {
                  if (val != null && val.isNotEmpty && !RegExp(r'^[A-Za-z0-9]*$').hasMatch(val)) {
                    return 'Only letters and numbers allowed';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Mute & Pause
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

              // Features (checkboxes)
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
                    onChanged: (v) => setState(() => _distinguishUnknownSpeakers = v!),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Connect / Token section
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
                              _isConnected ? Icons.check_circle : Icons.error,
                              color: _isConnected ? Colors.green : Colors.red,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isConnected ? 'Connected' : 'Not connected',
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: _isConnected ? Colors.green : Colors.red,
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
                                  }
                                });
                              },
                              icon: Icon(
                                _showTokenInput ? Icons.keyboard_arrow_up : Icons.vpn_key,
                                size: 18,
                              ),
                              label: Text(_showTokenInput ? 'Hide Token' : 'Manual Token'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.blue,
                              ),
                            ),
                            const SizedBox(width: 4),
                            ElevatedButton(
                              onPressed: _isConnecting ? null : _connectToInternal,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isConnected ? Colors.grey : Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                              child: _isConnecting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : Text(_isConnected ? 'Reconnect' : 'Connect'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (_showTokenInput) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _tokenController,
                              decoration: InputDecoration(
                                hintText: 'Paste token here...',
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                errorText: _tokenStatus.contains('❌') ? _tokenStatus : null,
                                helperText: _tokenStatus.contains('✅') ? _tokenStatus : null,
                                helperStyle: const TextStyle(color: Colors.green),
                              ),
                              maxLines: 2,
                              onChanged: (_) {
                                if (_tokenStatus.isNotEmpty) {
                                  setState(() => _tokenStatus = '');
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: _setManualToken,
                            icon: const Icon(Icons.save, size: 18),
                            label: const Text('Set'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton.icon(
                            onPressed: _clearManualToken,
                            icon: const Icon(Icons.clear, size: 18),
                            label: const Text('Clear'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                          ),
                        ],
                      ),
                      if (_tokenStatus.isNotEmpty && !_tokenStatus.contains('❌') && !_tokenStatus.contains('✅'))
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            _tokenStatus,
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Start Processing
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
              
              // Response display
              _buildResponseDisplay(),
            ],
          ),
        ),
      ),
    );
  }
}
