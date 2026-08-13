// job_configuration_screen.dart
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
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

  final List<String> _inputLanguages = ['en'];
  final List<String> _outputLanguages = ['de'];
  final List<String> _audioLanguages = ['de'];
  String _availability = 'private';
  bool _profanityFilter = true;
  bool _filterMusic = true;
  bool _enableSummarization = true;
  bool _enableLiveNotes = false;
  bool _enableDiarization = false;
  bool _enableAIAssistant = true;
  bool _saveSession = true;
  String _smartChaptering = 'online_dynamic';
  String _format = 'online';
  bool _isSubmitting = false;
  bool _isConnected = false;
  bool _isConnecting = false;

  // Manual token state
  bool _showTokenInput = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

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
    'online', 'mixed', 'resending', 'offline'
  ];
  static const List<String> _chapteringOptions = [
    'online_dynamic', 'online_static', 'offline', 'streaming_simple'
  ];

  // ─── Connection management ──────────────────────────────────────────────

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
        // Use mounted check before accessing context
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

  // ─── Manual token management ───────────────────────────────────────────────

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

  // ─── Token helper ──────────────────────────────────────────────────────────

  Future<String> _getToken() async {
    final token = await InternalAuthService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Not connected to internal server. Please click "Connect" or set a manual token first.');
    }
    return token;
  }

  // ─── Session name ──────────────────────────────────────────────────────────

  String _getDefaultSessionName() {
    final now = DateTime.now();
    final dateTimeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return '${widget.videoName} – $dateTimeStr';
  }

  @override
  void initState() {
    super.initState();
    _sessionNameController = TextEditingController(text: _getDefaultSessionName());
    _checkConnection();
  }

  @override
  void dispose() {
    _sessionNameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  // ─── Main submit ───────────────────────────────────────────────────────────

  Future<void> _submitJob() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSubmitting = true);

    try {
      final token = await _getToken();
      if (kDebugMode) print('🚀 [UPLOAD] Token fetched: $token');

      const userEmail = 'admin@example.com';

      // 1. Fetch video from local server
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

      // 2. Upload to internal server using cookie authentication
      await _uploadToInternalServer(
        videoBytes: videoBytes,
        fileName: widget.videoName,
        token: token,
        userEmail: userEmail,
        sessionName: _sessionNameController.text.trim(),
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
        smartChaptering: _smartChaptering,
        format: _format,
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

  // ─── Upload helper (multipart) ──────────────────────────────────────────

  Future<void> _uploadToInternalServer({
    required List<int> videoBytes,
    required String fileName,
    required String token,
    required String userEmail,
    required String sessionName,
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
    required String smartChaptering,
    required String format,
  }) async {
    const uploadUrl = kIsWeb
        ? '$authBaseUrl/upload-lecture'
        : '$internalServerUrl/upload_lecture';

    // Build fields exactly as in the Python script
    final fields = <String, String>{
      'path': '/home/$userEmail',
      'name': sessionName,
      'availability': availability,
      'topicname': sessionName,
      'date': DateTime.now().toIso8601String().split('T').first,
      'speakername': 'Christian Huber',
      'format': format,
      'smartChaptering': smartChaptering,
      'errorCorrection': 'None',
      'ttsQualityMode': 'high_quality',
    };

    for (final lang in inputLanguages) {
      fields['language'] = lang;
    }
    for (final lang in outputLanguages) {
      fields['mtLanguage'] = lang;
    }
    for (final lang in audioLanguages) {
      fields['audioLanguage'] = lang;
    }

    if (profanityFilter) fields['profanity'] = '1';
    if (filterMusic) fields['filter_music'] = '1';
    if (enableSummarization) fields['summarization'] = '1';
    if (enableLiveNotes) fields['notes'] = '1';
    if (enableDiarization) fields['saasr'] = '1';
    if (enableAIAssistant) fields['aiassistant'] = '1';

    if (kIsWeb) {
      // ─── 1. Store the token as a browser cookie ──────────────────────────
      // This makes the browser attach it automatically when we use withCredentials.
      html.document.cookie = '_forward_auth=$token; path=/;';

      // ─── 2. Build the multipart form data ────────────────────────────────
      final formData = html.FormData();
      fields.forEach((key, value) {
        formData.append(key, value);
      });

      final mimeType = lookupMimeType(fileName) ?? 'video/mp4';
      final blob = html.Blob([videoBytes], mimeType);
      formData.appendBlob('videofile', blob, fileName);

      // ─── 3. Create the request ────────────────────────────────────────────
      final request = html.HttpRequest();
      request.open('POST', uploadUrl, async: true);

      // ✅ Enable credentials so the browser sends the cookie from its jar
      request.withCredentials = true;

      // ❌ REMOVE the line that manually sets the Cookie header:
      // request.setRequestHeader('Cookie', '_forward_auth=$token');

      if (kDebugMode) {
        print('📤 [DEBUG] Upload URL (web proxy): $uploadUrl');
        print('📤 [DEBUG] File: $fileName ($mimeType, ${videoBytes.length} bytes)');
        print('📤 [DEBUG] Fields: $fields');
        print('🔑 [DEBUG] Cookie stored in document.cookie, will be sent automatically');
      }

      final completer = Completer<void>();
      request.onLoad.listen((_) => completer.complete());
      request.onError.listen((error) => completer.completeError(error));
      request.send(formData);
      await completer.future;

      final status = request.status;
      final responseText = request.responseText ?? '';
      final location = request.getResponseHeader('location');

      if (kDebugMode) {
        print('📥 [DEBUG] Upload response status (web): $status');
        print('📥 [DEBUG] Upload body preview: ${responseText.substring(0, responseText.length > 500 ? 500 : responseText.length)}');
      }

      _handleUploadResponse(status, location, responseText);
    } else {
      final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
      request.headers.addAll({
        'Cookie': '_forward_auth=$token',
      });
      request.fields.addAll(fields);

      final mimeType = lookupMimeType(fileName) ?? 'video/mp4';
      request.files.add(
        http.MultipartFile.fromBytes(
          'videofile',
          videoBytes,
          filename: fileName,
          contentType: http.MediaType.parse(mimeType),
        ),
      );

      if (kDebugMode) {
        print('📤 [DEBUG] Upload URL (non-web): $uploadUrl');
        print('📤 [DEBUG] File: $fileName ($mimeType, ${videoBytes.length} bytes)');
        print('📤 [DEBUG] Fields: $fields');
        print('🔑 [DEBUG] Sending cookie: _forward_auth=$token');
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (kDebugMode) {
        print('📥 [DEBUG] Upload response status: ${response.statusCode}');
        print('📥 [DEBUG] Upload body preview: ${response.body.substring(0, response.body.length > 500 ? 500 : response.body.length)}');
      }

      _handleUploadResponse(response.statusCode, response.headers['location'], response.body);
    }
  }

  void _handleUploadResponse(int? status, String? location, String body) {
    final effectiveStatus = status ?? 0;
    if (effectiveStatus == 302 || effectiveStatus == 303) {
      if (location == null) throw Exception('Redirect location missing.');
      final sessionId = Uri.parse(location).pathSegments.last;
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
    } else if (effectiveStatus == 200) {
      if (body.contains('dex') || body.contains('Log in')) {
        throw Exception('Authentication failed. Please log in again.');
      }
      throw Exception('Unexpected 200 response, expected redirect. Body: $body');
    } else {
      throw Exception('Upload failed (HTTP $effectiveStatus). $body');
    }
  }

  // ─── Dropdown helper ──────────────────────────────────────────────────────

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

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configure Job'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          // ─── CONNECT BUTTON IN APP BAR ────────────────────────────
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
              TextFormField(
                controller: _sessionNameController,
                decoration: const InputDecoration(
                  labelText: 'Session Name',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty
                    ? 'Please enter a name'
                    : null,
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

              // Features
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
                    title: const Text('Save Session'),
                    value: _saveSession,
                    onChanged: (v) => setState(() => _saveSession = v!),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ─── CONNECT BUTTON AND STATUS (above Start Processing) ──
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
                            // ─── MANUAL TOKEN TOGGLE BUTTON ──────────
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
                    // ─── MANUAL TOKEN INPUT ──────────────────────────
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

              // ─── Start Processing Button ────────────────────────────
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
            ],
          ),
        ),
      ),
    );
  }
}