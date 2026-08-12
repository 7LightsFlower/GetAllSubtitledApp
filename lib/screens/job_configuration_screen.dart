// job_configuration_screen.dart
import 'dart:async'; // for Completer
// ignore: deprecated_member_use
import 'dart:html' as html; // ignore: avoid_web_libraries_in_flutter
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
  State<JobConfigurationScreen> createState() =>
      _JobConfigurationScreenState();
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

  final List<String> _allInputLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'nl', 'pl', 'tr', 'uk', 'vi', 'th', 'id', 'ms'
  ];
  final List<String> _allOutputLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'nl', 'pl', 'tr', 'uk', 'vi', 'th'
  ];
  final List<String> _allAudioLanguages = [
    'en', 'de', 'fr', 'es', 'it', 'ja', 'ko', 'zh', 'ru', 'ar',
    'hi', 'pt', 'pl', 'tr', 'uk', 'vi', 'th'
  ];
  final List<String> _availabilityOptions = [
    'private', 'private+qr', 'kitemployee', 'kitall', 'public'
  ];
  final List<String> _formatOptions = [
    'online', 'mixed', 'resending', 'offline'
  ];
  final List<String> _chapteringOptions = [
    'online_dynamic', 'online_static', 'offline', 'streaming_simple'
  ];

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
    _sessionNameController =
        TextEditingController(text: _getDefaultSessionName());
  }

  @override
  void dispose() {
    _sessionNameController.dispose();
    super.dispose();
  }

  Future<void> _submitJob() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSubmitting = true);

    try {
      // ─── 1. Get internal auth token and user ─────────────────────
      final internalToken = await InternalAuthService.getValidAccessToken();
      if (internalToken == null) {
        throw Exception('Please log in to the internal server first.');
      }
      final userEmail = await InternalAuthService.getUserEmail();
      if (userEmail == null) {
        throw Exception('User email not available.');
      }

      const internalBaseUrl = internalServerUrl;

      // ─── 2. Fetch video bytes from the local server ──────────────
      const localBaseUrl = 'http://localhost:5000';
      final localMediaUrl =
          Uri.parse('$localBaseUrl/media/${widget.videoKey}');

      if (kDebugMode) {
        // ignore: avoid_print
        print('🌐 [DEBUG] Fetching video from local server: $localMediaUrl');
      }

      http.Response localResponse = await http.get(localMediaUrl);

      if (localResponse.statusCode != 200) {
        final fallbackUrl =
            Uri.parse('$localBaseUrl/videos/${widget.videoKey}/download');
        if (kDebugMode) {
          // ignore: avoid_print
          print('⚠️ [DEBUG] First attempt failed, trying fallback: $fallbackUrl');
        }
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

      if (kDebugMode) {
        // ignore: avoid_print
        print('✅ [DEBUG] Video fetched from local: ${videoBytes.length} bytes');
      }

      // ─── 3. Upload to internal server ────────────────────────────
      await _uploadToInternalServer(
        videoBytes: videoBytes,
        fileName: widget.videoName,
        internalToken: internalToken,
        userEmail: userEmail,
        internalBaseUrl: internalBaseUrl,
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
      if (kDebugMode) {
        // ignore: avoid_print
        print('❌ [DEBUG] Exception caught: $e');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 10),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // Helper method to perform the actual upload to the internal server
  Future<void> _uploadToInternalServer({
    required List<int> videoBytes,
    required String fileName,
    required String internalToken,
    required String userEmail,
    required String internalBaseUrl,
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
    final uploadUrl = '$internalBaseUrl/upload_lecture';

    // ─── Web: use dart:html to include cookies (withCredentials) ──
    if (kIsWeb) {
      final formData = html.FormData();

      // Add all fields
      formData.append('path', '/uploads');
      formData.append('name', sessionName);
      formData.append('availability', availability);
      for (final lang in inputLanguages) {
        formData.append('language', lang);
      }
      for (final lang in outputLanguages) {
        formData.append('mtLanguage', lang);
      }
      for (final lang in audioLanguages) {
        formData.append('audioLanguage', lang);
      }
      if (profanityFilter) formData.append('profanity', 'on');
      if (filterMusic) formData.append('filter_music', 'on');
      if (enableSummarization) formData.append('summarization', 'on');
      if (enableLiveNotes) formData.append('notes', 'on');
      if (enableDiarization) formData.append('saasr', '1');
      if (enableAIAssistant) formData.append('aiassistant', 'on');
      formData.append('smartChaptering', smartChaptering);
      formData.append('format', format);
      formData.append('topicname', sessionName);
      formData.append('date', DateTime.now().toIso8601String().split('T').first);
      formData.append('speakername', userEmail);

      // Determine MIME type and append the video file as a Blob
      final mimeType = lookupMimeType(fileName) ?? 'video/mp4';
      final blob = html.Blob([videoBytes], mimeType);
      formData.appendBlob('videofile', blob, fileName);

      // Prepare the request
      final request = html.HttpRequest();
      request.open('POST', uploadUrl, async: true);
      request.withCredentials = true; // send session cookies
      request.setRequestHeader('Authorization', 'Bearer $internalToken');
      request.setRequestHeader('X-Forwarded-User', userEmail);

      if (kDebugMode) {
        // ignore: avoid_print
        print('📤 [DEBUG] Upload URL (web): $uploadUrl');
        // ignore: avoid_print
        print('📤 [DEBUG] File: $fileName ($mimeType, ${videoBytes.length} bytes)');
      }

      // Use a Completer to wait for the request to finish
      final completer = Completer<void>();
      request.onLoad.listen((_) {
        completer.complete();
      });
      request.onError.listen((error) {
        completer.completeError(error);
      });
      // Send the request (synchronous)
      request.send(formData);

      // Wait for completion
      await completer.future;

      final status = request.status;
      final responseText = request.responseText ?? '';
      final location = request.getResponseHeader('location');

      if (kDebugMode) {
        // ignore: avoid_print
        print('📥 [DEBUG] Upload response status (web): $status');
        // ignore: avoid_print
        print('📥 [DEBUG] Upload headers (web): ${request.getAllResponseHeaders()}');
        final preview = responseText.length > 500
            ? '${responseText.substring(0, 500)}...'
            : responseText;
        // ignore: avoid_print
        print('📥 [DEBUG] Upload body preview (web): $preview');
      }

      // Handle response
      if (status == 302) {
        if (location == null) {
          throw Exception('Redirect location missing.');
        }
        final sessionId = Uri.parse(location).pathSegments.last;
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => LiveOutputScreen(
              videoKey: widget.videoKey,
              jobId: sessionId,
            ),
          ),
        );
      } else if (status == 200) {
        throw Exception('Unexpected 200 response, expected redirect. Body: $responseText');
      } else {
        throw Exception('Upload failed (HTTP $status). $responseText');
      }
      return;
    }

    // ─── Non‑web: use the existing http.MultipartRequest ────────────
    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

    request.headers.addAll({
      'Authorization': 'Bearer $internalToken',
      'X-Forwarded-User': userEmail,
    });

    request.fields['path'] = '/uploads';
    request.fields['name'] = sessionName;
    request.fields['availability'] = availability;

    for (final lang in inputLanguages) {
      request.fields['language'] = lang;
    }
    for (final lang in outputLanguages) {
      request.fields['mtLanguage'] = lang;
    }
    for (final lang in audioLanguages) {
      request.fields['audioLanguage'] = lang;
    }

    if (profanityFilter) request.fields['profanity'] = 'on';
    if (filterMusic) request.fields['filter_music'] = 'on';
    if (enableSummarization) request.fields['summarization'] = 'on';
    if (enableLiveNotes) request.fields['notes'] = 'on';
    if (enableDiarization) request.fields['saasr'] = '1';
    if (enableAIAssistant) request.fields['aiassistant'] = 'on';

    request.fields['smartChaptering'] = smartChaptering;
    request.fields['format'] = format;
    request.fields['topicname'] = sessionName;
    request.fields['date'] = DateTime.now().toIso8601String().split('T').first;
    request.fields['speakername'] = userEmail;

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
      // ignore: avoid_print
      print('📤 [DEBUG] Upload URL (non-web): $uploadUrl');
      // ignore: avoid_print
      print('📤 [DEBUG] Multipart fields:');
      request.fields.forEach((key, value) {
        // ignore: avoid_print
        print('    $key: $value');
      });
      // ignore: avoid_print
      print('📤 [DEBUG] File: $fileName ($mimeType, ${videoBytes.length} bytes)');
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (kDebugMode) {
      // ignore: avoid_print
      print('📥 [DEBUG] Upload response status: ${response.statusCode}');
      // ignore: avoid_print
      print('📥 [DEBUG] Upload headers: ${response.headers}');
      final bodyPreview = response.body.length > 500
          ? '${response.body.substring(0, 500)}...'
          : response.body;
      // ignore: avoid_print
      print('📥 [DEBUG] Upload body preview: $bodyPreview');
    }

    if (response.statusCode == 302) {
      final location = response.headers['location'];
      if (location == null) {
        throw Exception('Redirect location missing.');
      }
      final sessionId = Uri.parse(location).pathSegments.last;
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => LiveOutputScreen(
            videoKey: widget.videoKey,
            jobId: sessionId,
          ),
        ),
      );
    } else if (response.statusCode == 200) {
      throw Exception('Unexpected 200 response, expected redirect. Body: ${response.body}');
    } else {
      throw Exception('Upload failed (HTTP ${response.statusCode}). ${response.body}');
    }
  }

  // ─── Dropdown helper (unchanged) ──────────────────────────────────
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configure Job'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
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

              // Submit
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitJob,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                  child: _isSubmitting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Start Processing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
