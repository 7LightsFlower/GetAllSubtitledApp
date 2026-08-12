// job_configuration_screen.dart
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
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
  final List<String> _availabilityOptions = ['private', 'private+qr', 'kitemployee', 'kitall', 'public'];
  final List<String> _formatOptions = ['online', 'mixed', 'resending', 'offline'];
  final List<String> _chapteringOptions = ['online_dynamic', 'online_static', 'offline', 'streaming_simple'];

  String _getDefaultSessionName() {
    final now = DateTime.now();
    final dateTimeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return '${widget.videoName} – $dateTimeStr';
  }

  @override
  void initState() {
    super.initState();
    _sessionNameController = TextEditingController(text: _getDefaultSessionName());
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
      // ─── 0. Log the raw videoKey ────────────────────────────────
      if (kDebugMode) {
        print('📌 [DEBUG] Raw videoKey: ${widget.videoKey}');
        print('📌 [DEBUG] videoKey length: ${widget.videoKey.length}');
      }

      // ─── Get user and token ──────────────────────────────────────
      final internalToken = await InternalAuthService.getValidAccessToken();
      if (internalToken == null) {
        throw Exception('Please log in to the internal server first.');
      }
      final userEmail = await InternalAuthService.getUserEmail();
      if (userEmail == null) {
        throw Exception('User email not available.');
      }

      const baseUrl = internalServerUrl;

      // ─── 1. Decode videoKey and build the media URL ──────────────
      String dirPath;
      try {
        final decodedBytes = base64Decode(widget.videoKey);
        dirPath = utf8.decode(decodedBytes);
        if (kDebugMode) {
          print('✅ [DEBUG] Decoded directory path: "$dirPath"');
        }
      } catch (e) {
        // If decoding fails, the videoKey might already be plain text
        if (kDebugMode) {
          print('⚠️ [DEBUG] Base64 decode failed, treating videoKey as plain string.');
          print('⚠️ [DEBUG] Error: $e');
        }
        dirPath = widget.videoKey; // fallback – maybe it's a UUID or file path
      }

      final mediaUrl = Uri.parse('$baseUrl/archivemedia/${widget.videoKey}');
      if (kDebugMode) {
        print('🌐 [DEBUG] Fetching media from: $mediaUrl');
        print('🔑 [DEBUG] Authorization: Bearer ${internalToken.substring(0, 20)}...');
        print('👤 [DEBUG] X-Forwarded-User: $userEmail');
      }

      // ─── 2. Fetch video bytes ────────────────────────────────────
      final mediaResponse = await http.get(
        mediaUrl,
        headers: {
          'Authorization': 'Bearer $internalToken',
          'X-Forwarded-User': userEmail,
        },
      );

      if (kDebugMode) {
        print('📥 [DEBUG] Media response status: ${mediaResponse.statusCode}');
        print('📥 [DEBUG] Media response headers: ${mediaResponse.headers}');
        if (mediaResponse.statusCode != 200) {
          // Log the first 500 characters of the error body (may be HTML)
          final preview = mediaResponse.body.length > 500
              ? '${mediaResponse.body.substring(0, 500)}...'
              : mediaResponse.body;
          print('❌ [DEBUG] Error body preview: $preview');
        }
      }

      if (mediaResponse.statusCode != 200) {
        throw Exception(
          'Failed to fetch video (HTTP ${mediaResponse.statusCode}). '
          'Body: ${mediaResponse.body}'
        );
      }

      final videoBytes = mediaResponse.bodyBytes;
      if (videoBytes.isEmpty) {
        throw Exception('Video file is empty.');
      }

      if (kDebugMode) {
        print('✅ [DEBUG] Video bytes fetched: ${videoBytes.length} bytes');
      }

      // ─── 3. Extract parent directory and session name ────────────
      final parentDir = p.dirname(dirPath);
      final sessionName = _sessionNameController.text.trim();

      if (kDebugMode) {
        print('📁 [DEBUG] Parent directory: "$parentDir"');
        print('📝 [DEBUG] Session name: "$sessionName"');
      }

      // ─── 4. Build multipart request ──────────────────────────────
      final uploadUrl = Uri.parse('$baseUrl/upload_lecture');
      final request = http.MultipartRequest('POST', uploadUrl);

      request.headers.addAll({
        'Authorization': 'Bearer $internalToken',
        'X-Forwarded-User': userEmail,
      });

      // Fields
      request.fields['name'] = sessionName;
      request.fields['path'] = parentDir;
      request.fields['availability'] = _availability;

      for (final lang in _inputLanguages) {
        request.fields['language'] = lang;
      }
      for (final lang in _outputLanguages) {
        request.fields['mtLanguage'] = lang;
      }
      for (final lang in _audioLanguages) {
        request.fields['audioLanguage'] = lang;
      }

      if (_profanityFilter) request.fields['profanity'] = 'on';
      if (_filterMusic) request.fields['filter_music'] = 'on';
      if (_enableSummarization) request.fields['summarization'] = 'on';
      if (_enableLiveNotes) request.fields['notes'] = 'on';
      if (_enableDiarization) request.fields['saasr'] = '1';
      if (_enableAIAssistant) request.fields['aiassistant'] = 'on';

      request.fields['smartChaptering'] = _smartChaptering;
      request.fields['format'] = _format;
      request.fields['topicname'] = sessionName;
      request.fields['date'] = DateTime.now().toIso8601String().split('T').first;
      request.fields['speakername'] = userEmail;

      // File attachment
      final fileName = p.basename(dirPath);
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
        print('📤 [DEBUG] Upload URL: $uploadUrl');
        print('📤 [DEBUG] Multipart fields:');
        request.fields.forEach((key, value) {
          print('    $key: $value');
        });
        print('📤 [DEBUG] File: $fileName ($mimeType, ${videoBytes.length} bytes)');
      }

      // ─── 5. Send request ──────────────────────────────────────────
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (kDebugMode) {
        print('📥 [DEBUG] Upload response status: ${response.statusCode}');
        print('📥 [DEBUG] Upload headers: ${response.headers}');
        // Log body preview (may be HTML error page)
        final bodyPreview = response.body.length > 500
            ? '${response.body.substring(0, 500)}...'
            : response.body;
        print('📥 [DEBUG] Upload body preview: $bodyPreview');
      }

      // ─── 6. Handle response ──────────────────────────────────────
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
        // Might be a success page – try to extract session ID from HTML
        // For now, treat as error
        throw Exception('Unexpected 200 response, expected redirect. Body: ${response.body}');
      } else {
        throw Exception('Upload failed (HTTP ${response.statusCode}). ${response.body}');
      }
    } catch (e) {
      if (kDebugMode) {
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
              const Text('Output Languages (Translation)', style: TextStyle(fontWeight: FontWeight.bold)),
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
              const Text('Generated Audio Languages', style: TextStyle(fontWeight: FontWeight.bold)),
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

              // ─── Availability ──────────────────────────────────────
              _buildDropdownField<String>(
                label: 'Availability',
                value: _availability,
                options: _availabilityOptions,
                onChanged: (val) => setState(() => _availability = val!),
              ),
              const SizedBox(height: 16),

              // ─── Format ────────────────────────────────────────────
              _buildDropdownField<String>(
                label: 'Presentation Format',
                value: _format,
                options: _formatOptions,
                onChanged: (val) => setState(() => _format = val!),
              ),
              const SizedBox(height: 16),

              // ─── Smart Chaptering ──────────────────────────────────
              _buildDropdownField<String>(
                label: 'Smart Chaptering',
                value: _smartChaptering,
                options: _chapteringOptions,
                onChanged: (val) => setState(() => _smartChaptering = val!),
              ),
              const SizedBox(height: 16),

              // Features
              const Text('Features', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
