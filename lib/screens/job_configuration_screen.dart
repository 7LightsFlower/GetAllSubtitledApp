// job_configuration_screen.dart
import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/screens/session_output_screen.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/widgets/job_progress_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class JobConfigurationScreen extends StatefulWidget {
  final String videoKey;
  final String videoName;
  final String? sessionId;

  const JobConfigurationScreen({
    super.key,
    required this.videoKey,
    required this.videoName,
    this.sessionId,
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
  String? _thumbnailUrl;

  // Language lists using ISO 639-1 codes from LanguageConfig
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

  // Settings panel collapsed state
  bool _settingsExpanded = false;

  // Manual token state
  bool _showTokenInput = false;
  final TextEditingController _tokenController = TextEditingController();
  String _tokenStatus = '';

  // Response display state
  String _responseMessage = '';
  String _responseHtml = '';
  String _sessionUrl = '';
  String _sessionId = '';
  String _videoKey = '';
  bool _showResponse = false;

  // Output checking state
  bool _hasSessionId = false;
  String _savedSessionId = '';
  String _savedSessionUrl = '';
  bool _isCheckingOutput = false;
  String _outputStatus = '';

  // Job history
  List<Map<String, dynamic>> _jobHistory = [];
  bool _isLoadingHistory = false;

  // --- Constants ---
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
    _fetchThumbnail();
    _loadJobHistory();

    if (widget.sessionId != null && widget.sessionId!.isNotEmpty) {
      _savedSessionId = widget.sessionId!;
      _hasSessionId = true;
      _outputStatus = '✅ Session ID loaded: ${widget.sessionId}\nClick "Check Output" to see results.';
    }
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

  // --- Job History Management ---
  Future<void> _loadJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      final jsonString = prefs.getString(key);
      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> history = jsonDecode(jsonString);
        setState(() {
          _jobHistory = history.cast<Map<String, dynamic>>();
          // Sort by date, newest first
          _jobHistory.sort((a, b) => (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));
        });
      }
    } catch (e) {
      if (kDebugMode) print('Error loading job history: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _saveJobToHistory({
    required String sessionId,
    required String sessionUrl,
    required String sessionName,
    required String status,
    required bool hasOutput,
    int outputFiles = 0,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      
      // Check if this session already exists in history
      final existingIndex = _jobHistory.indexWhere(
        (job) => job['session_id'] == sessionId
      );
      
      if (existingIndex != -1) {
        // Update existing entry instead of creating new one
        _jobHistory[existingIndex]['status'] = status;
        _jobHistory[existingIndex]['has_output'] = hasOutput;
        if (outputFiles > 0) {
          _jobHistory[existingIndex]['output_files'] = outputFiles;
        }
      } else {
        // Add new entry
        final jobEntry = {
          'session_id': sessionId,
          'session_url': sessionUrl,
          'session_name': sessionName,
          'timestamp': DateTime.now().toIso8601String(),
          'date': _date,
          'status': status,
          'has_output': hasOutput,
          'output_files': outputFiles,
          'input_languages': _inputLanguages.join(','),
          'output_languages': _outputLanguages.join(','),
          'availability': _availability,
        };
        
        _jobHistory.insert(0, jobEntry);
      }
      
      // Keep only last 20 jobs per video
      if (_jobHistory.length > 20) {
        _jobHistory = _jobHistory.sublist(0, 20);
      }
      
      // Save to shared preferences
      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);
      
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (kDebugMode) print('Error saving job history: $e');
    }
  }

  Future<void> _deleteJobFromHistory(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      
      _jobHistory.removeWhere((job) => job['session_id'] == sessionId);
      
      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);
      
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job removed from history')),
        );
      }
    } catch (e) {
      if (kDebugMode) print('Error deleting job: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting job: $e')),
        );
      }
    }
  }

  Future<void> _clearAllHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History?'),
        content: Text('This will remove all ${_jobHistory.length} jobs for this video.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final key = 'job_history_${widget.videoKey}';
        await prefs.remove(key);
        setState(() {
          _jobHistory.clear();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('History cleared')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error clearing history: $e')),
          );
        }
      }
    }
  }

  // --- Fetch thumbnail ---
  Future<void> _fetchThumbnail() async {
    try {
      final token = await InternalAuthService.getToken();
      if (token == null || token.isEmpty) return;
      
      final response = await http.get(
        Uri.parse('$authBaseUrl/video_detail/${widget.videoKey}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final thumbnailUrl = data['thumbnail_url'] as String?;
        if (mounted && thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
          setState(() {
            _thumbnailUrl = thumbnailUrl;
          });
        }
      }
    } catch (e) {
      if (kDebugMode) print('Failed to fetch thumbnail: $e');
    }
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

  // --- Output checking methods ---
  Future<void> _checkOutput() async {
    if (_savedSessionId.isEmpty) {
      if (mounted) {
        setState(() {
          _outputStatus = '❌ No session ID available. Please upload a video first.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isCheckingOutput = true;
        _outputStatus = '🔄 Checking for output files...';
      });
    }

    try {
      final token = await _getToken();
      final url = '$flaskServerUrl/session_output/$_savedSessionId';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        if (totalFiles > 0) {
          // Update job history - find and update existing entry instead of creating new one
          final jobIndex = _jobHistory.indexWhere(
            (job) => job['session_id'] == _savedSessionId
          );
          if (jobIndex != -1) {
            // Update existing entry
            setState(() {
              _jobHistory[jobIndex]['has_output'] = true;
              _jobHistory[jobIndex]['status'] = 'Completed ✅';
              _jobHistory[jobIndex]['output_files'] = totalFiles;
            });
            // Save updated history
            await _saveJobHistoryToPrefs();
          } else {
            // If not found in history, add it (shouldn't happen normally)
            await _saveJobToHistory(
              sessionId: _savedSessionId,
              sessionUrl: _savedSessionUrl,
              sessionName: _sessionNameController.text.trim(),
              status: 'Completed ✅',
              hasOutput: true,
              outputFiles: totalFiles,
            );
          }

          if (mounted) {
            setState(() {
              _isCheckingOutput = false;
              _outputStatus = '✅ Output is ready! Found $totalFiles files.';
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Output ready! $totalFiles files available.'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          if (mounted) {
            setState(() {
              _isCheckingOutput = false;
              _outputStatus = '⏳ Still processing... No output files found yet.\n'
                            'Please wait a few more minutes and try again.';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _isCheckingOutput = false;
            _outputStatus = '❌ Failed to check output: ${response.statusCode}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingOutput = false;
          _outputStatus = '❌ Error checking output: $e';
        });
      }
    }
  }

  // Helper method to save history to preferences
  Future<void> _saveJobHistoryToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'job_history_${widget.videoKey}';
      final jsonString = jsonEncode(_jobHistory);
      await prefs.setString(key, jsonString);
    } catch (e) {
      if (kDebugMode) print('Error saving job history: $e');
    }
  }

  void _viewHistoricalOutput(String sessionId, String sessionUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionOutputScreen(
          sessionId: sessionId,
          sessionUrl: sessionUrl.isNotEmpty 
              ? sessionUrl 
              : 'https://lt2srv-sscherrer.isl.iar.kit.edu/archivesession/$sessionId',
        ),
      ),
    );
  }

  // --- Language toggle methods ---
  void _toggleInputLanguage(String lang) {
    setState(() {
      if (_inputLanguages.contains(lang)) {
        _inputLanguages.remove(lang);
      } else {
        _inputLanguages.add(lang);
      }
    });
  }

  void _toggleOutputLanguage(String lang) {
    setState(() {
      if (_outputLanguages.contains(lang)) {
        _outputLanguages.remove(lang);
      } else {
        _outputLanguages.add(lang);
      }
    });
  }

  void _toggleAudioLanguage(String lang) {
    setState(() {
      if (_audioLanguages.contains(lang)) {
        _audioLanguages.remove(lang);
      } else {
        _audioLanguages.add(lang);
      }
    });
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

    // Send ISO 639-1 language codes
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
    // Make sure fileName has .mp4 extension
    String uploadFileName = fileName;
    if (!uploadFileName.toLowerCase().endsWith('.mp4')) {
      uploadFileName = '$uploadFileName.mp4';
    }
    formData.appendBlob('videofile', blob, uploadFileName);

    final request = html.HttpRequest();
    request.open('POST', uploadUrl);
    request.send(formData);
    await request.onLoadEnd.first;

    final status = request.status ?? 0;
    final responseText = request.responseText;
    final finalUrl = request.responseUrl;

    // Flag to prevent duplicate history entries
    bool historySaved = false;

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
            _videoKey = data['video_key'] ?? '';
            _showResponse = true;
          });
          _printSessionLink();
        } catch (_) {
          // Parse HTML response and save session ID
          final parsedSessionId = _parseHtmlResponseAndReturnSessionId(responseText ?? '');
          if (parsedSessionId != null && parsedSessionId.isNotEmpty) {
            if (mounted) {
              await InternalAuthService.saveSessionId(widget.videoKey, parsedSessionId);
            }
          }

          if (mounted) {
            setState(() {
              _responseMessage = responseText ?? 'Upload successful!';
              _showResponse = true;
            });
          }
          _printSessionLink();
        }
      }

      // Check for session ID in redirect URL
      if (finalUrl != null && finalUrl.contains('/archivesession/')) {
        final sessionId = finalUrl.split('/archivesession/')[-1].split('/')[0];
        if (mounted) {
          setState(() {
            _sessionId = sessionId;
            _sessionUrl = finalUrl;
            _savedSessionId = sessionId;
            _savedSessionUrl = finalUrl;
            _hasSessionId = true;
            _outputStatus = '✅ Upload complete! Session ID: $sessionId\n'
                          'Click "Check Output" to see if processing is finished.';
          });

          // Save session ID
          await InternalAuthService.saveSessionId(widget.videoKey, sessionId);
          
          // Save to job history ONLY if not already saved
          if (!historySaved) {
            await _saveJobToHistory(
              sessionId: sessionId,
              sessionUrl: finalUrl,
              sessionName: _sessionNameController.text.trim(),
              status: 'Processing... ⏳',
              hasOutput: false,
            );
            historySaved = true;
          }
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Upload complete! Session ID: $sessionId'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
        return;
      }

      // Check for session ID in JSON response
      try {
        final data = jsonDecode(responseText ?? '');
        final sessionId = data['session_id']?.toString();
        if (sessionId != null && sessionId.isNotEmpty) {
          if (mounted) {
            setState(() {
              _sessionId = sessionId;
              _sessionUrl = data['session_url'] ?? '';
              _savedSessionId = sessionId;
              _savedSessionUrl = data['session_url'] ?? '';
              _hasSessionId = true;
              _outputStatus = '✅ Upload complete! Session ID: $sessionId\n'
                            'Click "Check Output" to see if processing is finished.';
            });
            
            // Save session ID
            await InternalAuthService.saveSessionId(widget.videoKey, sessionId);
            
            // Save to job history ONLY if not already saved
            if (!historySaved) {
              await _saveJobToHistory(
                sessionId: sessionId,
                sessionUrl: data['session_url'] ?? '',
                sessionName: _sessionNameController.text.trim(),
                status: 'Processing... ⏳',
                hasOutput: false,
              );
              historySaved = true;
            }
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ Upload complete! Session ID: $sessionId'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
          return;
        }
      } catch (_) {}

      // If no session ID, just show the response and stay on this screen
      return;
    }
  }
      
  String? _parseHtmlResponseAndReturnSessionId(String html) {
    final RegExp linkRegex = RegExp(r'<a href="([^"]+)"[^>]*>([^<]+)</a>');
    final linkMatch = linkRegex.firstMatch(html);
    if (linkMatch != null) {
      final url = linkMatch.group(1) ?? '';
      if (url.isNotEmpty) {
        String cleanUrl = url.replaceAll(RegExp(r'\s+'), '');
        cleanUrl = cleanUrl.replaceAll('ist.iar', 'isl.iar');
        _sessionUrl = cleanUrl;
        
        if (cleanUrl.contains('/archivesession/')) {
          final sessionId = cleanUrl.split('/archivesession/')[-1].split('/')[0];
          final cleanedId = sessionId.replaceAll(RegExp(r'\s+'), '').split('"')[0];
          if (cleanedId.isNotEmpty) {
            _sessionId = cleanedId;
            return cleanedId;
          }
        }
      }
    }
    
    final RegExp videoKeyRegex = RegExp(r'<strong>Video Key:</strong>\s*([^<]+)');
    final videoMatch = videoKeyRegex.firstMatch(html);
    if (videoMatch != null && videoMatch.groupCount >= 1) {
      _videoKey = videoMatch.group(1)?.trim() ?? '';
    }
    
    if (_sessionId.isEmpty) {
      final RegExp sessionIdRegex = RegExp(r'<strong>Session ID:</strong>\s*([^<]+)');
      final sessionMatch = sessionIdRegex.firstMatch(html);
      if (sessionMatch != null && sessionMatch.groupCount >= 1) {
        _sessionId = sessionMatch.group(1)?.trim() ?? '';
        if (_sessionId.isNotEmpty) {
          return _sessionId;
        }
      }
    }
    
    return null;
  }

  void _printSessionLink() {
    if (_sessionUrl.isNotEmpty && kDebugMode) {
      if (kDebugMode) {
        print('═══════════════════════════════════════════════════════════');
      }
      if (kDebugMode) {
        print('📎 SESSION LINK:');
      }
      if (kDebugMode) {
        print(_sessionUrl);
      }
      if (kDebugMode) {
        print('═══════════════════════════════════════════════════════════');
      }
    }
    if (_sessionId.isNotEmpty && kDebugMode) {
      if (kDebugMode) {
        print('🆔 SESSION ID: $_sessionId');
      }
    }
    if (_videoKey.isNotEmpty && kDebugMode) {
      if (kDebugMode) {
        print('🎬 VIDEO KEY: $_videoKey');
      }
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
          
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[700]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '✅ Upload Successful!',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          if (_savedSessionId.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session ID: $_savedSessionId',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          
          const SizedBox(height: 12),
          
          if (_sessionUrl.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.link, color: Colors.blue),
                      SizedBox(width: 8),
                      Text(
                        '📎 Session Link:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: InkWell(
                      onTap: () {
                        html.window.open(_sessionUrl, '_blank');
                      },
                      child: Text(
                        _sessionUrl,
                        style: TextStyle(
                          color: Colors.blue[700],
                          decoration: TextDecoration.underline,
                          fontSize: 13,
                        ),
                        softWrap: true,
                      ),
                    ),
                  ),
                  if (_sessionId.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.fingerprint, size: 14, color: Colors.grey),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Session ID:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                                Text(
                                  _sessionId,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[700],
                                  ),
                                  softWrap: true,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          
          if (_videoKey.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.video_label, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Video Key: $_videoKey',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          
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
                  'Response Preview:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _stripHtmlTags(_responseHtml),
                    style: const TextStyle(fontSize: 12),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
              ElevatedButton.icon(
                onPressed: _showFullResponseDialog,
                icon: const Icon(Icons.open_in_full),
                label: const Text('View Full Response'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _showResponse = false;
                  });
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Check output for a historical job
  Future<void> _checkHistoricalOutput(String sessionId) async {
    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔄 Checking output status...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final token = await _getToken();
      final url = '$flaskServerUrl/session_output/$sessionId';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final totalFiles = data['total_files'] ?? 0;

        // Find and update the job in history
        final jobIndex = _jobHistory.indexWhere(
          (job) => job['session_id'] == sessionId
        );
        
        if (jobIndex != -1) {
          if (totalFiles > 0) {
            setState(() {
              _jobHistory[jobIndex]['has_output'] = true;
              _jobHistory[jobIndex]['status'] = 'Completed ✅';
              _jobHistory[jobIndex]['output_files'] = totalFiles;
            });
            await _saveJobHistoryToPrefs();
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ Output ready! Found $totalFiles files.'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 3),
                ),
              );
              // Refresh the history display
              setState(() {});
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('⏳ Still processing... No output files found yet.'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Failed to check output: ${response.statusCode}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error checking output: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // --- Job History Widget ---
  Widget _buildJobHistory() {
    if (_jobHistory.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: Column(
          children: [
            Icon(Icons.history, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              'No previous jobs for this video',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 4),
            Text(
              'Start your first processing job above',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.history, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'Job History (${_jobHistory.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_sweep, size: 20),
                  onPressed: _clearAllHistory,
                  tooltip: 'Clear all history',
                  color: Colors.red,
                ),
              ],
            ),
          ),
          // List
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _jobHistory.length,
            separatorBuilder: (_, __) => Divider(color: Colors.grey[200]),
            itemBuilder: (context, index) {
              final job = _jobHistory[index];
              final timestamp = DateTime.tryParse(job['timestamp'] ?? '');
              final dateStr = timestamp != null
                  ? '${timestamp.day}/${timestamp.month}/${timestamp.year} ${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}'
                  : job['date'] ?? 'Unknown date';
              final sessionName = job['session_name'] ?? 'Unknown Session';
              final status = job['status'] ?? 'Unknown';
              final hasOutput = job['has_output'] ?? false;
              final sessionId = job['session_id'] ?? '';
              final sessionUrl = job['session_url'] ?? '';
              final outputFiles = job['output_files'] ?? 0;
              final isProcessing = status.contains('Processing') || !hasOutput;

              Color statusColor;
              IconData statusIcon;
              if (hasOutput) {
                statusColor = Colors.green;
                statusIcon = Icons.check_circle;
              } else if (isProcessing) {
                statusColor = Colors.orange;
                statusIcon = Icons.hourglass_empty;
              } else {
                statusColor = Colors.grey;
                statusIcon = Icons.help_outline;
              }

              return Material(
                color: Colors.transparent,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: statusColor.withValues(alpha: 0.2),
                    child: Icon(statusIcon, size: 20, color: statusColor),
                  ),
                  title: Text(
                    sessionName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ID: ${sessionId.length > 20 ? '${sessionId.substring(0, 20)}...' : sessionId}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      Text(
                        '📅 $dateStr • ${job['input_languages'] ?? 'N/A'} → ${job['output_languages'] ?? 'N/A'}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                      if (hasOutput)
                        Text(
                          '📁 $outputFiles file${outputFiles > 1 ? 's' : ''} available',
                          style: TextStyle(fontSize: 11, color: Colors.green[700]),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasOutput)
                        Icon(
                          Icons.file_download_done,
                          size: 18,
                          color: Colors.green[400],
                        ),
                      const SizedBox(width: 4),
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      PopupMenuButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: (value) {
                          if (value == 'view' && sessionId.isNotEmpty) {
                            _viewHistoricalOutput(sessionId, sessionUrl);
                          } else if (value == 'check' && sessionId.isNotEmpty) {
                            _checkHistoricalOutput(sessionId);
                          } else if (value == 'delete') {
                            _deleteJobFromHistory(sessionId);
                          } else if (value == 'open' && sessionUrl.isNotEmpty) {
                            html.window.open(sessionUrl, '_blank');
                          }
                        },
                        itemBuilder: (context) => [
                          if (hasOutput || sessionUrl.isNotEmpty)
                            const PopupMenuItem(
                              value: 'view',
                              child: Row(
                                children: [
                                  Icon(Icons.folder_open, size: 18),
                                  SizedBox(width: 8),
                                  Text('View Output'),
                                ],
                              ),
                            ),
                          if (!hasOutput)
                            const PopupMenuItem(
                              value: 'check',
                              child: Row(
                                children: [
                                  Icon(Icons.refresh, size: 18, color: Colors.blue),
                                  SizedBox(width: 8),
                                  Text('Check Status', style: TextStyle(color: Colors.blue)),
                                ],
                              ),
                            ),
                          if (sessionUrl.isNotEmpty)
                            const PopupMenuItem(
                              value: 'open',
                              child: Row(
                                children: [
                                  Icon(Icons.open_in_new, size: 18),
                                  SizedBox(width: 8),
                                  Text('Open Session'),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete, size: 18, color: Colors.red),
                                SizedBox(width: 8),
                                Text('Delete', style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  onTap: () {
                    if (hasOutput) {
                      _viewHistoricalOutput(sessionId, sessionUrl);
                    } else {
                      _checkHistoricalOutput(sessionId);
                    }
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // --- Output check section widget ---
  Widget _buildOutputCheckSection() {
    if (!_hasSessionId) return const SizedBox.shrink();
    
    // Find the current session in history
    final currentJobIndex = _jobHistory.indexWhere(
      (job) => job['session_id'] == _savedSessionId
    );
    final bool hasOutput = currentJobIndex != -1 && 
                          (_jobHistory[currentJobIndex]['has_output'] ?? false);
    final int outputFiles = currentJobIndex != -1 ? 
                            (_jobHistory[currentJobIndex]['output_files'] ?? 0) : 0;
    
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.folder_outlined, color: Colors.blue),
              SizedBox(width: 8),
              Text(
                'Current Session',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Session ID: $_savedSessionId',
            style: const TextStyle(fontSize: 12),
          ),
          if (hasOutput) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.check_circle, size: 14, color: Colors.green),
                const SizedBox(width: 4),
                Text(
                  '✅ Output ready ($outputFiles files)',
                  style: TextStyle(fontSize: 12, color: Colors.green[700]),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (_outputStatus.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _outputStatus,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!hasOutput)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isCheckingOutput ? null : _checkOutput,
                    icon: _isCheckingOutput
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
                      _isCheckingOutput ? 'Checking...' : 'Check Status',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              if (hasOutput) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Find the job and view its output
                      final job = _jobHistory.firstWhere(
                        (j) => j['session_id'] == _savedSessionId,
                        orElse: () => {},
                      );
                      _viewHistoricalOutput(
                        _savedSessionId, 
                        job['session_url'] ?? _savedSessionUrl
                      );
                    },
                    icon: const Icon(Icons.folder_open),
                    label: Text('View Output ($outputFiles files)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isCheckingOutput ? null : _checkOutput,
                    icon: _isCheckingOutput
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: Text(
                      _isCheckingOutput ? 'Checking...' : 'Refresh',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _stripHtmlTags(String html) {
    String text = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™')
        .replaceAll('&bull;', '•')
        .replaceAll('&hellip;', '…');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  String _extractVideoKey(String html) {
    final RegExp regex = RegExp(r'<strong>Video Key:</strong>\s*([^<]+)');
    final match = regex.firstMatch(html);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)?.trim() ?? '';
    }
    return '';
  }

  void _showFullResponseDialog() {
    final String cleanText = _stripHtmlTags(_responseHtml);
    final String videoKey = _extractVideoKey(_responseHtml);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blue),
            SizedBox(width: 8),
            Text('Full Server Response'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                const SizedBox(height: 16),
              ],
              if (videoKey.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Video Key: $videoKey',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      cleanText.isNotEmpty ? cleanText : _responseMessage,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
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

  // --- Build settings panel ---
  Widget _buildSettingsPanel() {
    final inputLangCodes = LanguageConfig.getSortedInputLanguages();
    final outputLangCodes = LanguageConfig.getSortedOutputLanguages();
    final audioLangCodes = LanguageConfig.getSortedAudioLanguages();

    return Column(
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: inputLangCodes.map((code) {
            final displayName = LanguageConfig.getInputLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _inputLanguages.contains(code),
              onSelected: (selected) {
                _toggleInputLanguage(code);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Output Languages
        const Text('Output Languages (Translation)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: outputLangCodes.map((code) {
            final displayName = LanguageConfig.getOutputLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _outputLanguages.contains(code),
              onSelected: (selected) {
                _toggleOutputLanguage(code);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Audio Languages
        const Text('Generated Audio Languages',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: audioLangCodes.map((code) {
            final displayName = LanguageConfig.getAudioLanguageName(code);
            return FilterChip(
              label: Text('$displayName ($code)'),
              selected: _audioLanguages.contains(code),
              onSelected: (selected) {
                _toggleAudioLanguage(code);
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

        // Post-production
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
      ],
    );
  }

  Widget _buildLiveProgressPanel() {
    if (!_hasSessionId || _savedSessionId.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: JobProgressPanel(
        // Key on the session id so a new submission gets a fresh panel
        // (with a fresh poll timer) instead of reusing the old state.
        key: ValueKey('job-progress-$_savedSessionId'),
        sessionId: _savedSessionId,
        onComplete: () {
          if (!mounted) return;
          setState(() {
            _outputStatus =
                '✅ Processing complete! Click "View Output" to browse files.';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Processing complete'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          // Refresh the manual check section so it shows "Output ready"
          _checkOutput();
        },
      ),
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
              // ─── Video Preview Card ──────
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _thumbnailUrl != null && _thumbnailUrl!.isNotEmpty
                          ? Image.network(
                              _thumbnailUrl!,
                              height: 60,
                              width: 80,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                height: 60,
                                width: 80,
                                color: Colors.grey[300],
                                child: const Icon(Icons.videocam, size: 24),
                              ),
                            )
                          : Container(
                              height: 60,
                              width: 80,
                              color: Colors.grey[300],
                              child: const Icon(Icons.videocam, size: 24),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.videoName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Key: ${widget.videoKey.substring(0, 32)}...',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[500],
                            ),
                          ),
                          if (_jobHistory.isNotEmpty)
                            Text(
                              '📋 ${_jobHistory.length} job${_jobHistory.length > 1 ? 's' : ''} processed',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.blue[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ─── Job History ───
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    leading: Icon(
                      Icons.history,
                      color: _jobHistory.isNotEmpty ? Colors.blue : Colors.grey,
                    ),
                    title: Row(
                      children: [
                        const Text(
                          'Job History',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_jobHistory.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_jobHistory.length}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                    initiallyExpanded: _jobHistory.isNotEmpty,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _isLoadingHistory
                            ? const Center(child: CircularProgressIndicator())
                            : _buildJobHistory(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ─── Expandable Settings Panel ───
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    leading: Icon(
                      _settingsExpanded ? Icons.settings : Icons.settings,
                      color: Colors.blue,
                    ),
                    title: Row(
                      children: [
                        const Text(
                          'Job Settings',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_inputLanguages.length} in · ${_outputLanguages.length} out',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    initiallyExpanded: _settingsExpanded,
                    onExpansionChanged: (expanded) {
                      setState(() {
                        _settingsExpanded = expanded;
                      });
                    },
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildSettingsPanel(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ─── Connect / Token section ───
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

              // ─── Start Processing ───
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
              
              // ─── Live progress panel ───          👈 NEW
              _buildLiveProgressPanel(),
              
              // ─── Output check section ───
              _buildOutputCheckSection(),
              
              // ─── Response display ───
              _buildResponseDisplay(),
            ],
          ),
        ),
      ),
    );
  }
}
