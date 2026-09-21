// session_output_screen.dart - Fixed without ignoring warnings

import 'package:asr_live_translator/theme/responsive.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/session_data.dart';
import 'package:asr_live_translator/models/subtitle_track.dart'; 
import 'package:asr_live_translator/widgets/video_player_widget.dart';
import 'package:asr_live_translator/widgets/transcript_view.dart';
import 'package:asr_live_translator/widgets/chapter_seekbar.dart';
import 'package:asr_live_translator/widgets/export_dialog.dart';
import 'package:asr_live_translator/widgets/language_selector.dart';

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

// Custom VTT Cue class
class VTTCue {
  final int index;
  final double start;
  final double end;
  final String text;
  final String? speaker;

  const VTTCue({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
  });

  @override
  String toString() {
    return 'VTTCue(index: $index, start: $start, end: $end, text: $text, speaker: $speaker)';
  }
}

class _SessionOutputScreenState extends State<SessionOutputScreen> {
  VideoPlayerController? _videoController;
  List<TranscriptData> _transcripts = [];
  final List<ChapterData> _chapters = [];
  List<SessionFile> _files = [];
  bool _isLoading = true;
  bool _isSplitView = false;
  bool _showFileList = false;
  bool _isEditingMode = false;
  bool _isSaving = false;
  String _selectedLanguage = '';
  String _secondaryLanguage = '';
  String _errorMessage = '';
  String _videoUrl = '';
  
  int _currentSegmentIndex = -1;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _secondaryScrollController = ScrollController();
  bool _isVideoReady = false;

  // Subtitle related variables - properly initialized
  List<SubtitleTrack> _subtitleTracks = const [];
  String? _selectedSubtitle;
  Map<String, List<VTTCue>> _parsedSubtitles = const {};


  @override
  void initState() {
    super.initState();
    _loadSessionData();
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    _scrollController.dispose();
    _secondaryScrollController.dispose();
    super.dispose();
  }

  // ─── CUSTOM VTT PARSER ──────────────────────────────────────────────

  /// Parse VTT content into a list of VTTCue objects
  List<VTTCue> _parseVTT(String content) {
    final List<VTTCue> cues = [];
    final lines = content.split('\n');
    
    bool inCue = false;
    String currentText = '';
    double cueStart = 0.0;
    double cueEnd = 0.0;
    int cueIndex = 0;
    String? speaker;
    
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      
      // Skip empty lines
      if (line.isEmpty) continue;
      
      // Skip WEBVTT header
      if (line.startsWith('WEBVTT')) continue;
      if (line.startsWith('Kind:')) continue;
      if (line.startsWith('Language:')) continue;
      
      // Check if this is a timestamp line (contains -->)
      if (line.contains('-->')) {
        // Save previous cue if exists
        if (inCue && currentText.isNotEmpty) {
          cues.add(VTTCue(
            index: cueIndex,
            start: cueStart,
            end: cueEnd,
            text: currentText.trim(),
            speaker: speaker,
          ));
          cueIndex++;
          currentText = '';
          speaker = null;
        }
        
        // Parse timestamps
        final parts = line.split('-->');
        if (parts.length == 2) {
          cueStart = _parseVTTTimestamp(parts[0].trim());
          cueEnd = _parseVTTTimestamp(parts[1].trim());
          inCue = true;
        }
      } 
      // Check if this is a cue index (just a number)
      else if (RegExp(r'^\d+$').hasMatch(line)) {
        // This is a cue number, skip it
        continue;
      }
      // This is text content
      else if (inCue) {
        // Check for speaker tag: <v Speaker Name>text</v>
        final speakerMatch = RegExp(r'<v\s+([^>]+)>([^<]*)</v>').firstMatch(line);
        if (speakerMatch != null) {
          speaker = speakerMatch.group(1)?.trim();
          String text = speakerMatch.group(2)?.trim() ?? '';
          if (text.isNotEmpty) {
            if (currentText.isNotEmpty) currentText += ' ';
            currentText += text;
          }
        } else {
          // Remove any other HTML tags
          String cleanText = line.replaceAll(RegExp(r'<[^>]+>'), '').trim();
          if (cleanText.isNotEmpty) {
            if (currentText.isNotEmpty) currentText += ' ';
            currentText += cleanText;
          }
        }
      }
    }
    
    // Save the last cue
    if (inCue && currentText.isNotEmpty) {
      cues.add(VTTCue(
        index: cueIndex,
        start: cueStart,
        end: cueEnd,
        text: currentText.trim(),
        speaker: speaker,
      ));
    }
    
    return cues;
  }

  /// Parse VTT timestamp (00:00:00.000 or 00:00.000) to seconds
  double _parseVTTTimestamp(String timestamp) {
    // Replace comma with dot for decimal
    timestamp = timestamp.replaceAll(',', '.');
    
    final parts = timestamp.split(':');
    if (parts.length == 3) {
      // Format: HH:MM:SS.mmm
      final hours = double.tryParse(parts[0]) ?? 0;
      final minutes = double.tryParse(parts[1]) ?? 0;
      final seconds = double.tryParse(parts[2]) ?? 0;
      return hours * 3600 + minutes * 60 + seconds;
    } else if (parts.length == 2) {
      // Format: MM:SS.mmm
      final minutes = double.tryParse(parts[0]) ?? 0;
      final seconds = double.tryParse(parts[1]) ?? 0;
      return minutes * 60 + seconds;
    }
    return 0.0;
  }

  /// Get subtitle text at specific time
  String? _getSubtitleAtTime(double time) {
    if (_selectedSubtitle == null) return null;
    
    final cues = _parsedSubtitles[_selectedSubtitle];
    if (cues == null || cues.isEmpty) return null;
    
    // Find the cue that contains the current time
    for (final cue in cues) {
      if (time >= cue.start && time <= cue.end) {
        return cue.text;
      }
    }
    
    return null;
  }


  Future<void> _loadSubtitleTracks() async {
    final List<SubtitleTrack> newTracks = [];
    final Map<String, List<VTTCue>> newParsed = {};
    
    // Find all VTT files
    final allVttFiles = _files.where((f) => 
      f.name.endsWith('.vtt') && 
      f.name != 'subtitles.vtt'
    ).toList();
    
    if (allVttFiles.isEmpty) {
      debugPrint('No VTT files found');
      return;
    }
    
    // Group VTT files by language
    // First, try to find simple-named ones (subtitles_English.vtt, etc.)
    // These are the preferred ones
    final Map<String, List<SessionFile>> languageFiles = {};
    
    for (final file in allVttFiles) {
      String language = _extractLanguageFromFilename(file.name);
      if (!languageFiles.containsKey(language)) {
        languageFiles[language] = [];
      }
      languageFiles[language]!.add(file);
    }
    
    // Sort languages - put "Original ASR" first if it exists
    final sortedLanguages = languageFiles.keys.toList()..sort((a, b) {
      // Prioritize Original ASR
      if (a.contains('Original') && !b.contains('Original')) return -1;
      if (!a.contains('Original') && b.contains('Original')) return 1;
      // Then sort alphabetically
      return a.compareTo(b);
    });
    
    final token = await InternalAuthService.getToken();
    
    for (final language in sortedLanguages) {
      final files = languageFiles[language]!;
      // Prefer files with simpler names (no special characters)
      // Sort by filename length (shorter is better)
      files.sort((a, b) => a.name.length.compareTo(b.name.length));
      
      // Try to load the best file for this language
      for (final file in files) {
        try {
          // Use the URL from the file object
          final url = file.url.startsWith('http') 
              ? file.url 
              : '$flaskServerUrl${file.url}';
          
          debugPrint('Loading subtitle for language "$language" from: $url');
          
          final response = await http.get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer ${token ?? ''}',
            },
          );
          
          if (response.statusCode == 200) {
            final content = response.body;
            final cues = _parseVTT(content);
            
            if (cues.isNotEmpty) {
              newParsed[language] = cues;
              newTracks.add(SubtitleTrack(
                language: language,
                label: _getLanguageLabel(language),
                url: url,
                content: content,
              ));
              debugPrint('Loaded subtitle: ${file.name} (${cues.length} cues)');
              break; // Successfully loaded this language
            }
          }
        } catch (e) {
          debugPrint('Failed to load subtitle ${file.name}: $e');
        }
      }
    }
    
    setState(() {
      _subtitleTracks = newTracks;
      _parsedSubtitles = newParsed;
      
      if (_subtitleTracks.isNotEmpty && _selectedSubtitle == null) {
        _selectedSubtitle = _subtitleTracks.first.language;
      }
    });
  }

  /// Extract language name from filename.
  String _extractLanguageFromFilename(String filename) {
    String name = filename
        .replaceFirst('subtitles_', '')
        .replaceFirst('.vtt', '');
    name = Uri.decodeComponent(name);
    if (name == 'Transcript') return 'Transcript';
    return resolveLanguageName(name);
  }

  /// Get language label for display.
  String _getLanguageLabel(String language) {
    if (language.contains('Original ASR')) return 'Transcript';
    if (language.contains('Translation')) return language;
    if (language.contains('Structured')) return language;
    return resolveLanguageName(language);
  }

  /// Called by VideoPlayerWidget when the user picks a different subtitle track.
  void _onSubtitleChanged(String? language) {
    setState(() {
      _selectedSubtitle = language;
    });
  }

  Future<void> _updateVideoSubtitles() async {
    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Video Subtitles'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('• Embed edited VTT subtitles into the video file'),
            Text('• Update messages.json with the edited content'),
            Text('• Keep all your changes in sync'),
            SizedBox(height: 12),
            Text(
              'This may take a few moments. Continue?',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
    
    if (confirm != true) return;
    
    setState(() {
      _isLoading = true;
    });
    
    try {
      final token = await InternalAuthService.getToken();
      final url = '$flaskServerUrl/update_video_subtitles/${widget.sessionId}';
      
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // Show detailed success message
        final subtitleCount = data['embedded_subtitles']?.length ?? 0;
        final messagesUpdated = data['messages_updated'] ?? 0;
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ ${data['message']}\nEmbedded: $subtitleCount tracks, Updated: $messagesUpdated messages'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 5),
            ),
          );
          
          // Reload data to show updates
          await _loadSessionData();
        }
      } else {
        throw Exception('Failed to update video: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to update video: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ─── END OF VTT PARSING ──────────────────────────────────────────────

  Future<void> _loadSessionData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _isEditingMode = false;
    });

    try {
      final token = await InternalAuthService.getToken();
      
      final outputUrl = '$flaskServerUrl/session_output/${widget.sessionId}';
      final outputResponse = await http.get(
        Uri.parse(outputUrl),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (outputResponse.statusCode != 200) {
        setState(() {
          _errorMessage = 'Failed to load session: ${outputResponse.statusCode}';
          _isLoading = false;
        });
        return;
      }

      final outputData = jsonDecode(outputResponse.body);
      final filesData = outputData['files'] as List? ?? [];
      _files = filesData.map((f) => SessionFile.fromJson(f)).toList();

      // Sort files by modification date
      _files.sort((a, b) {
        if (a.modified == null && b.modified == null) return 0;
        if (a.modified == null) return 1;
        if (b.modified == null) return -1;
        return b.modified!.compareTo(a.modified!);
      });

      final transcriptUrl = '$flaskServerUrl/session_transcript_json/${widget.sessionId}';
      final transcriptResponse = await http.get(
        Uri.parse(transcriptUrl),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (transcriptResponse.statusCode == 200) {
        final transcriptData = jsonDecode(transcriptResponse.body);
        if (transcriptData is List) {
          _transcripts = transcriptData
              .map((t) => TranscriptData.fromJson(t))
              .toList();
          
          if (_transcripts.isNotEmpty) {
            _selectedLanguage = _transcripts.first.language;
            _secondaryLanguage = _transcripts.length > 1
                ? _transcripts[1].language
                : _transcripts.first.language;
            _extractChapters();
          }
        }
      }

      final videoFile = _files.firstWhere(
        (f) => f.name.endsWith('.mp4') || f.name.endsWith('.webm'),
        orElse: () => const SessionFile(name: '', size: 0, url: ''),
      );

      if (videoFile.name.isNotEmpty) {
        _videoUrl = '$flaskServerUrl/session_file/${widget.sessionId}/${videoFile.name}';
        _initializeVideoPlayer();
      }

      // Load subtitle tracks after files are loaded
      await _loadSubtitleTracks();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  void _extractChapters() {
    _chapters.clear();
    
    final transcript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty ? _transcripts.first : TranscriptData.empty(),
    );
    
    if (transcript.segments.isEmpty) return;

    ChapterData? currentChapter;
    for (final segment in transcript.segments) {
      if (segment.markup == 'chapterBreak') {
        currentChapter = ChapterData(
          start: segment.start,
          end: segment.end,
          index: _chapters.length,
          heading: '',
          segments: [],
        );
        _chapters.add(currentChapter);
      } else if (segment.markup == 'heading' && currentChapter != null) {
        currentChapter = currentChapter.copyWith(heading: segment.text);
        _chapters[_chapters.length - 1] = currentChapter;
      } else if (currentChapter != null && 
                 (segment.markup == null || segment.markup == 'paragraphBreak')) {
        final updatedSegments = List<SegmentData>.from(currentChapter.segments)
          ..add(segment);
        currentChapter = currentChapter.copyWith(segments: updatedSegments);
        _chapters[_chapters.length - 1] = currentChapter;
      }
    }

    if (_chapters.isEmpty && transcript.segments.isNotEmpty) {
      _chapters.add(ChapterData(
        start: 0,
        end: _videoController?.value.duration.inSeconds.toDouble() ?? 120,
        index: 0,
        heading: 'Full Session',
        segments: List.from(transcript.segments),
      ));
    }
  }

  void _initializeVideoPlayer() {
    // Tear down any previous controller so a reload never leaves a stale
    // video playing in the background.
    final old = _videoController;
    if (old != null) {
      old.removeListener(_onVideoProgress);
      old.dispose();
      _videoController = null;
    }

    // Default state on load / reload: stopped.
    // We initialize the controller (so the first frame and duration are
    // available) but do NOT call play(). The user starts playback with
    // the play button.
    _videoController = VideoPlayerController.networkUrl(
      Uri.parse(_videoUrl),
    )..initialize().then((_) {
        if (!mounted) {
          // Widget was disposed while we were initializing.
          _videoController?.dispose();
          _videoController = null;
          return;
        }
        setState(() {
          _isVideoReady = true;
        });
        _videoController!.addListener(_onVideoProgress);
        // NOTE: no play() here — the video stays paused until the user
        // presses the play button.
      }).catchError((error) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'Failed to load video: $error';
        });
      });
  }
  
  void _onVideoProgress() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    
    final currentTime = _videoController!.value.position.inMilliseconds / 1000.0;
    
    final transcript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty ? _transcripts.first : TranscriptData.empty(),
    );
    
    if (transcript.segments.isEmpty) return;

    int newIndex = -1;
    for (int i = 0; i < transcript.segments.length; i++) {
      final seg = transcript.segments[i];
      if (currentTime >= seg.start && currentTime < seg.end) {
        newIndex = i;
        break;
      }
    }
    
    if (newIndex != _currentSegmentIndex) {
      setState(() {
        _currentSegmentIndex = newIndex;
      });
    }
  }

  void _toggleSplitView() {
    setState(() {
      _isSplitView = !_isSplitView;
    });
  }

  void _toggleFileList() {
    setState(() {
      _showFileList = !_showFileList;
    });
  }

  void _toggleEditingMode() {
    setState(() {
      _isEditingMode = !_isEditingMode;
    });
  }

  void _selectLanguage(String language) {
    setState(() {
      _selectedLanguage = language;
    });
    _extractChapters();
  }

  void _selectSecondaryLanguage(String language) {
    setState(() {
      _secondaryLanguage = language;
    });
  }

  void _togglePlayPause() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    
    if (_videoController!.value.isPlaying) {
      _videoController!.pause();
    } else {
      _videoController!.play();
    }
    setState(() {});
  }

  void _seekTo(double seconds) {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    _videoController!.seekTo(Duration(milliseconds: (seconds * 1000).toInt()));
  }

  void _jumpToChapter(ChapterData chapter) {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    _videoController!.seekTo(Duration(milliseconds: (chapter.start * 1000).toInt()));
  }

  void _downloadFile(SessionFile file) async {
    try {
      final token = await InternalAuthService.getToken();
      final downloadUrl = '$flaskServerUrl/session_file/${widget.sessionId}/${file.name}';
      
      final response = await http.get(
        Uri.parse(downloadUrl),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (response.statusCode == 200) {
        final blob = html.Blob([response.bodyBytes]);
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', file.name)
          ..click();
        html.Url.revokeObjectUrl(url);

        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded: ${file.name}')),
        );
      } else {
        throw Exception('Download failed: ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Download failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  bool _isDownloadingAll = false;

  Future<void> _downloadAllFiles() async {
    if (_files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No files to download'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (_isDownloadingAll) return;          // guard against double-tap

    setState(() => _isDownloadingAll = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preparing download… This may take a moment.'),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final token = await InternalAuthService.getToken();

      // IMPORTANT: encode the session id so '/', '+', '=' don't break the URL
      final encodedId = Uri.encodeComponent(widget.sessionId);
      final downloadUrl = '$flaskServerUrl/session_zip/$encodedId';

      final response = await http.get(
        Uri.parse(downloadUrl),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
      );

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }
      if (response.bodyBytes.isEmpty) {
        throw Exception('Server returned an empty ZIP');
      }

      // Parse filename from Content-Disposition if present
      String filename = 'session_${widget.sessionId}.zip';
      final cd = response.headers['content-disposition'] ?? '';
      final m = RegExp(r'filename\*?=(?:UTF-8'')?"?([^";]+)"?').firstMatch(cd);
      if (m != null && m.group(1)!.trim().isNotEmpty) {
        filename = Uri.decodeComponent(m.group(1)!.trim());
      }
      // Sanitize — a filename can never contain '/' or '\'
      filename = filename.replaceAll(RegExp(r'[\\/]'), '_');

      final blob = html.Blob([response.bodyBytes], 'application/zip');
      final url = html.Url.createObjectUrlFromBlob(blob);

      // Attach, click, then revoke AFTER the browser has begun the download
      final anchor = html.AnchorElement(href: url)
        ..download = filename
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();

      Future.delayed(const Duration(seconds: 1), () {
        html.Url.revokeObjectUrl(url);
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Downloaded: $filename'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e, st) {
      debugPrint('Download-all failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Download failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _isDownloadingAll = false);
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (context) => ExportDialog(
        sessionId: widget.sessionId,
        languages: _transcripts.map((t) => t.language).toList(),
      ),
    );
  }

  // Helper method to convert SegmentData to JSON
  Map<String, dynamic> _segmentToJson(SegmentData segment) {
    return {
      'text': segment.text,
      'start': segment.start,
      'end': segment.end,
      'sender': segment.sender,
      if (segment.markup != null) 'markup': segment.markup,
      if (segment.words != null) 'words': segment.words,
      if (segment.wordId != null) 'word_id': segment.wordId,
      if (segment.sourceTokens != null) 'source_tokens': segment.sourceTokens,
      if (segment.speakerName != null) 'speaker_name': segment.speakerName,
      if (segment.refinedSentenceCluster != null) 'refined_sentence_cluster': segment.refinedSentenceCluster,
      'unstable': segment.unstable,
      if (segment.messageId != null) 'message_id': segment.messageId,
    };
  }

  // Helper method to create a copy of SegmentData with new text
  SegmentData _copySegmentWithText(SegmentData segment, String newText) {
    return SegmentData(
      text: newText,
      start: segment.start,
      end: segment.end,
      sender: segment.sender,
      markup: segment.markup,
      words: segment.words,
      wordId: segment.wordId,
      sourceTokens: segment.sourceTokens,
      speakerName: segment.speakerName,
      refinedSentenceCluster: segment.refinedSentenceCluster,
      unstable: segment.unstable,
      messageId: segment.messageId,
    );
  }

  // Save edited transcript
  Future<void> _saveEditedTranscript(TranscriptData editedTranscript) async {
    setState(() {
      _isSaving = true;
    });

    try {
      final token = await InternalAuthService.getToken();
      
      final index = _transcripts.indexWhere(
        (t) => t.language == editedTranscript.language
      );
      
      if (index != -1) {
        _transcripts[index] = editedTranscript;
      }
      
      // Dynamically determine the filename
      String vttFilename = '';
      
      // Try to find an existing VTT file for this language
      final existingVtt = _files.firstWhere(
        (f) => f.name.endsWith('.vtt') && 
              f.name != 'subtitles.vtt' &&
              (_extractLanguageFromFilename(f.name) == _extractLanguageFromFilename(editedTranscript.language) ||
                f.name.contains(_extractSimpleLanguage(editedTranscript.language))),
        orElse: () => const SessionFile(name: '', size: 0, url: ''),
      );
      
      if (existingVtt.name.isNotEmpty) {
        vttFilename = existingVtt.name;
      } else {
        // Create a clean filename
        String cleanLanguage = _extractSimpleLanguage(editedTranscript.language);
        vttFilename = 'subtitles_$cleanLanguage.vtt';
      }

      final saveUrl = '$flaskServerUrl/session_transcript_save_vtt/${widget.sessionId}';
      
      final requestBody = jsonEncode({
        'language': editedTranscript.language,
        'segments': editedTranscript.segments.map((s) => _segmentToJson(s)).toList(),
        'filename': vttFilename,
      });
      
      final response = await http.post(
        Uri.parse(saveUrl),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
          'Content-Type': 'application/json',
        },
        body: requestBody,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        
        // Update files list from response
        if (responseData.containsKey('files')) {
          final filesData = responseData['files'] as List? ?? [];
          _files = filesData.map((f) => SessionFile.fromJson(f)).toList();
        } else {
          // Reload files if not in response
          final outputUrl = '$flaskServerUrl/session_output/${widget.sessionId}';
          final outputResponse = await http.get(
            Uri.parse(outputUrl),
            headers: {
              'Authorization': 'Bearer ${token ?? ''}',
            },
          );

          if (outputResponse.statusCode == 200) {
            final outputData = jsonDecode(outputResponse.body);
            final filesData = outputData['files'] as List? ?? [];
            _files = filesData.map((f) => SessionFile.fromJson(f)).toList();
          }
        }

        // Reload subtitle tracks after saving
        await _loadSubtitleTracks();
        
        // Force the video player to reload subtitles
        if (_selectedSubtitle != null) {
          final currentSubtitle = _selectedSubtitle;
          setState(() {
            _selectedSubtitle = null;
          });
          await Future.delayed(const Duration(milliseconds: 100));
          setState(() {
            _selectedSubtitle = currentSubtitle;
          });
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Transcript saved and VTT updated: ${responseData['vtt_filename']}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception('Failed to save transcript. Server returned: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error saving transcript: $e');
      await _downloadVTT(editedTranscript);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isEditingMode = false;
        });
      }
    }
  }

  /// Extract simple language name (without parentheses or special characters)
  String _extractSimpleLanguage(String language) {
    final name = resolveLanguageName(language);
    return name.replaceAll(' ', '_');
  }

  // Download VTT directly - simplified version without unused variable
  Future<void> _downloadVTT(TranscriptData transcript) async {
    try {
      final filename = '${transcript.language}_edited.vtt';
      
      // Create blob directly from the generated content
      final blob = html.Blob([_generateVTTContent(transcript)], 'text/vtt');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.Url.revokeObjectUrl(url);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Downloaded edited VTT: $filename'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to generate VTT: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  // Save and download VTT
  Future<void> _saveAndDownloadVTT(TranscriptData editedTranscript) async {
    try {
      await _downloadVTT(editedTranscript);
      
      final index = _transcripts.indexWhere(
        (t) => t.language == editedTranscript.language
      );
      
      if (index != -1) {
        setState(() {
          _transcripts[index] = editedTranscript;
        });
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ VTT downloaded for ${editedTranscript.language}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to download VTT: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // In session_output_screen.dart - Update _generateVTTContent

  String _generateVTTContent(TranscriptData transcript) {
    final buffer = StringBuffer();
    buffer.writeln('WEBVTT');
    buffer.writeln();
    
    int cueIndex = 0;
    for (final segment in transcript.segments) {
      // Skip segments with invalid timestamps (start == end == 0)
      // These are usually summaries, global summaries, etc.
      if (segment.start == 0 && segment.end == 0) continue;
      
      // Skip empty text
      if (segment.text.trim().isEmpty) continue;
      
      // Skip markup segments that don't contain text
      if (segment.markup == 'paragraphBreak') continue;
      if (segment.markup == 'chapterBreak') continue;
      if (segment.markup == 'heading') continue;
      
      cueIndex++;
      buffer.writeln('$cueIndex');
      
      final startTime = _formatVTTTimestamp(segment.start);
      final endTime = _formatVTTTimestamp(segment.end);
      buffer.writeln('$startTime --> $endTime');
      
      // Clean the text - remove any HTML tags
      String cleanText = segment.text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (cleanText.isEmpty) continue;
      
      // Add speaker name if available
      if (segment.speakerName != null && segment.speakerName!.isNotEmpty) {
        // Remove any HTML from speaker name too
        final cleanSpeaker = segment.speakerName!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        buffer.writeln('<v $cleanSpeaker>$cleanText</v>');
      } else {
        buffer.writeln(cleanText);
      }
      
      buffer.writeln();
    }
    
    return buffer.toString();
  }

  String _formatVTTTimestamp(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).toInt());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);
    
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final currentTranscript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty ? _transcripts.first : TranscriptData.empty(),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Output'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_isEditingMode ? Icons.check : Icons.edit),
            onPressed: currentTranscript.segments.isNotEmpty && !_isSaving ? _toggleEditingMode : null,
            tooltip: _isEditingMode ? 'Save Changes' : 'Edit Transcript',
            color: _isEditingMode ? Colors.green : Colors.white,
          ),
          IconButton(
            icon: Icon(_showFileList ? Icons.description : Icons.folder),
            onPressed: _toggleFileList,
            tooltip: _showFileList ? 'Show Transcript' : 'Show Files',
          ),
          IconButton(
            icon: Icon(_isSplitView ? Icons.view_column : Icons.view_column_outlined),
            onPressed: _toggleSplitView,
            tooltip: 'Toggle Split View',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _showExportDialog,
            tooltip: 'Export Transcript',
          ),
          IconButton(
            icon: _isDownloadingAll
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.folder_zip),
            onPressed: (_files.isNotEmpty && !_isDownloadingAll)
                ? _downloadAllFiles
                : null,
            tooltip: 'Download All Files',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSessionData,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.subtitles_off),
            onPressed: () async {
              // Force reload subtitle tracks
              await _loadSubtitleTracks();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('🔄 Subtitles reloaded'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            tooltip: 'Reload Subtitles',
          ),
          IconButton(
            icon: const Icon(Icons.video_settings),
            onPressed: _updateVideoSubtitles,
            tooltip: 'Update Video Subtitles',
          ),
        ],
      ),
      body: _buildBody(currentTranscript),
    );
  }

  Widget _buildBody(TranscriptData currentTranscript) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadSessionData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_transcripts.isEmpty && _files.isEmpty) {
      return const Center(
        child: Text('No data available'),
      );
    }

    final r = Responsive.of(context);
    final videoHeight = r.videoHeight;
    final screenWidth = r.width;

    return Column(
      children: [
                // ─── Video player ────────────────────────────────────────────
        Container(
          height: videoHeight,
          color: Colors.black,
          child: Stack(
            children: [
              // Video player
              Center(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: screenWidth * 0.9,
                    maxHeight: videoHeight,
                  ),
                  child: VideoPlayerWidget(
                    controller: _videoController,
                    isReady: _isVideoReady,
                    onPlayPause: _togglePlayPause,
                    onSeek: _seekTo,
                    height: videoHeight,
                    subtitleTracks: _subtitleTracks.isNotEmpty
                        ? _subtitleTracks
                        : null,
                    selectedSubtitle: _selectedSubtitle,
                    onSubtitleChanged: _onSubtitleChanged,
                  ),
                ),
              ),

              // Subtitle overlay
              if (_selectedSubtitle != null && _parsedSubtitles.isNotEmpty)
                Positioned(
                  bottom: r.subtitleOverlayBottom,
                  left: r.spaceL,
                  right: r.spaceL,
                  child: AnimatedOpacity(
                    opacity: 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _getSubtitleAtTime(
                              _videoController
                                      ?.value.position.inSeconds
                                      .toDouble() ??
                                  0,
                            ) ??
                            '',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: r.subtitleOverlayFont,
                          fontWeight: FontWeight.w500,
                          shadows: const [
                            Shadow(blurRadius: 4, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              // ─── Chapter strip — pinned to the bottom of the black
              //     video pane, same 90 %-width as the video itself. ──
              if (_chapters.isNotEmpty && _isVideoReady)
                Positioned(
                  bottom: 0,
                  left: screenWidth * 0.05,
                  right: screenWidth * 0.05,
                  child: SizedBox(
                    height: r.chapterBarHeight,
                    child: ChapterSeekbar(
                      chapters: _chapters,
                      currentTime: _videoController
                              ?.value.position.inSeconds
                              .toDouble() ??
                          0,
                      onTap: _jumpToChapter,
                    ),
                  ),
                ),
            ],
          ),
        ),


        // ─── File list OR transcript panel ───────────────────────────
        Expanded(
          child: _showFileList
              ? _buildFileList()
              : Column(
                  children: [
                    // Language selector bar
                    Container(
                      constraints:
                          BoxConstraints(maxWidth: screenWidth * 0.9),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 4),
                      child: _isSplitView
                          // ── Split view: one selector pinned to each side
                          ? Row(
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: LanguageSelector(
                                      transcripts: _transcripts,
                                      selectedLanguage: _selectedLanguage,
                                      onLanguageSelected: _selectLanguage,
                                      enabled:
                                          !_isEditingMode && !_isSaving,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: LanguageSelector(
                                      transcripts: _transcripts,
                                      selectedLanguage:
                                          _secondaryLanguage,
                                      onLanguageSelected:
                                          _selectSecondaryLanguage,
                                      enabled:
                                          !_isEditingMode && !_isSaving,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          // ── Single view: one selector on the left,
                          //    EDITING badge / spinner on the right
                          : Row(
                              children: [
                                LanguageSelector(
                                  transcripts: _transcripts,
                                  selectedLanguage: _selectedLanguage,
                                  onLanguageSelected: _selectLanguage,
                                  enabled: !_isEditingMode && !_isSaving,
                                ),
                                const Spacer(),
                                if (_isEditingMode)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    margin:
                                        const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'EDITING',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                if (_isSaving)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ),
                              ],
                            ),
                    ),

                    // Transcript view
                    Expanded(
                      child: _isSplitView
                          ? _buildSplitTranscriptView()
                          : _buildEditableTranscriptView(
                              currentTranscript,
                              currentTranscript,
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildEditableTranscriptView(TranscriptData transcript, TranscriptData currentTranscript) {
    if (_isEditingMode) {
      return _buildEditableTranscript(currentTranscript);
    } else {
      return TranscriptView(
        transcript: transcript,
        highlightedIndex: _currentSegmentIndex,
        scrollController: _scrollController,
      );
    }
  }

  Widget _buildEditableTranscript(TranscriptData transcript) {
    final List<SegmentData> editableSegments = List.from(transcript.segments);
    final List<TextEditingController> textControllers = [];
    final List<FocusNode> focusNodes = [];

    for (int i = 0; i < editableSegments.length; i++) {
      final controller = TextEditingController(text: editableSegments[i].text);
      textControllers.add(controller);
      focusNodes.add(FocusNode());
      
      final index = i;
      controller.addListener(() {
        editableSegments[index] = _copySegmentWithText(
          editableSegments[index],
          controller.text,
        );
      });
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.grey.shade100,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Language label — shrinks first
              Expanded(
                child: Text(
                  'Editing: ${transcript.language}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              // Buttons — scroll horizontally if they still don't fit
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _isSaving
                            ? null
                            : () {
                                for (final c in textControllers) {
                                  c.dispose();
                                }
                                for (final f in focusNodes) {
                                  f.dispose();
                                }
                                setState(() => _isEditingMode = false);
                              },
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isSaving
                            ? null
                            : () async {
                                final updatedTranscript = TranscriptData(
                                  language: transcript.language,
                                  text: transcript.text,
                                  segments: editableSegments,
                                  sender: transcript.sender,
                                );
                                await _saveEditedTranscript(updatedTranscript);
                              },
                        icon: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.cloud_upload),
                        label: Text(_isSaving ? 'Saving…' : 'Save to Server'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isSaving
                            ? null
                            : () async {
                                final updatedTranscript = TranscriptData(
                                  language: transcript.language,
                                  text: transcript.text,
                                  segments: editableSegments,
                                  sender: transcript.sender,
                                );
                                await _saveAndDownloadVTT(updatedTranscript);
                              },
                        icon: const Icon(Icons.download),
                        label: const Text('Download VTT'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
                Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: editableSegments.length,
            itemBuilder: (context, index) {
              final segment = editableSegments[index];
              final isHighlighted = index == _currentSegmentIndex;
              
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: isHighlighted ? Colors.yellow.shade100 : Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isHighlighted ? Colors.yellow.shade700 : Colors.grey.shade300,
                    width: isHighlighted ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        _formatTimestamp(segment.start),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: TextField(
                        controller: textControllers[index],
                        focusNode: focusNodes[index],
                        maxLines: null,
                        enabled: !_isSaving,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Edit segment text...',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 4,
                          ),
                        ),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'End: ${_formatTimestamp(segment.end)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontFamily: 'monospace',
                            ),
                          ),
                          if (segment.markup != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                segment.markup!,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.blue.shade800,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).toInt());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);
    
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
    }
  }

  Widget _getFileIcon(String filename) {
    final r = Responsive.of(context);
    final size = r.iconLarge;
    if (filename.endsWith('.mp4') || filename.endsWith('.webm')) {
      return Icon(Icons.video_file, color: Colors.blue, size: size);
    } else if (filename.endsWith('.wav') || filename.endsWith('.mp3')) {
      return Icon(Icons.audio_file, color: Colors.green, size: size);
    } else if (filename.endsWith('.vtt') || filename.endsWith('.srt')) {
      return Icon(Icons.subtitles, color: Colors.orange, size: size);
    } else if (filename.endsWith('.html') || filename.endsWith('.htm')) {
      return Icon(Icons.html, color: Colors.purple, size: size);
    } else if (filename.endsWith('.zip')) {
      return Icon(Icons.folder_zip, color: Colors.brown, size: size);
    } else if (filename.endsWith('.json')) {
      return Icon(Icons.code, color: Colors.teal, size: size);
    } else if (filename.endsWith('.rtf')) {
      return Icon(Icons.description, color: Colors.orange, size: size);
    } else if (filename.endsWith('.docx') || filename.endsWith('.doc')) {
      return Icon(Icons.file_present, color: Colors.blue, size: size);
    } else if (filename.endsWith('.txt')) {
      return Icon(Icons.text_snippet, color: Colors.grey, size: size);
    } else if (filename == 'transcripts.json') {
      return Icon(Icons.data_array, color: Colors.deepPurple, size: size);
    } else if (filename == 'messages.json') {
      return Icon(Icons.message, color: Colors.indigo, size: size);
    } else if (filename == 'index.html') {
      return Icon(Icons.web, color: Colors.orange, size: size);
    } else {
      return Icon(Icons.insert_drive_file, color: Colors.grey, size: size);
    }
  }

  Widget _buildFileList() {
    if (_files.isEmpty) {
      return const Center(child: Text('No files available'));
    }

    final r = Responsive.of(context);

    return ListView.builder(
      padding: EdgeInsets.all(r.spaceL),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        return Card(
          margin: EdgeInsets.only(bottom: r.spaceS),
          child: ListTile(
            leading: _getFileIcon(file.name),
            title: Text(
              file.name,
              style: TextStyle(
                fontSize: r.fileListTitleFont,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: r.spaceXS),
                Text(
                  _formatFileSize(file.size),
                  style: TextStyle(fontSize: r.fileListMetaFont + 1),
                ),
                if (file.modified != null)
                  Text(
                    'Modified: ${_formatDate(file.modified!)}',
                    style: TextStyle(
                      fontSize: r.fileListMetaFont,
                      color: Colors.grey,
                    ),
                  ),
              ],
            ),
            trailing: IconButton(
              icon: Icon(Icons.download,
                  color: Colors.blue, size: r.iconMedium - 2),
              onPressed: () => _downloadFile(file),
              tooltip: 'Download',
            ),
            onTap: () => _downloadFile(file),
          ),
        );
      },
    );
  }

  String _formatDate(String isoDate) {
    try {
      final dateTime = DateTime.parse(isoDate);
      final now = DateTime.now();
      final difference = now.difference(dateTime);
      
      if (difference.inHours < 24) {
        if (difference.inHours < 1) {
          if (difference.inMinutes < 1) {
            return 'Just now';
          }
          return '${difference.inMinutes}m ago';
        }
        return '${difference.inHours}h ago';
      }
      
      return '${dateTime.day.toString().padLeft(2, '0')}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.year} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }

  Widget _buildSplitTranscriptView() {
    if (_transcripts.length < 2) {
      return TranscriptView(
        transcript: _transcripts.isNotEmpty
            ? _transcripts.first
            : TranscriptData.empty(),
        highlightedIndex: _currentSegmentIndex,
        scrollController: _scrollController,
      );
    }

    // Honour the *chosen* languages instead of always taking the first two.
    final left = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.first,
    );
    final right = _transcripts.firstWhere(
      (t) => t.language == _secondaryLanguage,
      orElse: () => _transcripts.length > 1 ? _transcripts[1] : _transcripts.first,
    );

    return Row(
      children: [
        Expanded(
          child: _isEditingMode
              ? _buildEditableTranscript(left)
              : TranscriptView(
                  transcript: left,
                  highlightedIndex: _currentSegmentIndex,
                  scrollController: _scrollController,
                ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _isEditingMode
              ? _buildEditableTranscript(right)
              : TranscriptView(
                  transcript: right,
                  highlightedIndex: _currentSegmentIndex,
                  scrollController: _secondaryScrollController,
                ),
        ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
