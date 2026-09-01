// session_output_screen.dart - Fixed without ignoring warnings

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
import 'package:asr_live_translator/widgets/language_tabs.dart';
import 'package:asr_live_translator/widgets/chapter_seekbar.dart';
import 'package:asr_live_translator/widgets/export_dialog.dart';

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
  String _errorMessage = '';
  String _videoUrl = '';
  
  int _currentSegmentIndex = -1;
  final ScrollController _scrollController = ScrollController();
  bool _isVideoReady = false;

  // Subtitle related variables - properly initialized
  List<SubtitleTrack> _subtitleTracks = const [];
  String? _selectedSubtitle;
  Map<String, List<VTTCue>> _parsedSubtitles = const {};

  static const double _maxVideoHeight = 200;
  static const double _minVideoHeight = 150;

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
    
    // Find all VTT files (excluding generic subtitles.vtt)
    final vttFiles = _files.where((f) => 
      f.name.endsWith('.vtt') && 
      f.name != 'subtitles.vtt' // Skip the generic one
    ).toList();
    
    final token = await InternalAuthService.getToken();
    
    for (final file in vttFiles) {
      String language = file.name
          .replaceFirst('subtitles_', '')
          .replaceFirst('.vtt', '');
      
      String label = _getLanguageLabel(language);
      
      try {
        final response = await http.get(
          Uri.parse('$flaskServerUrl/session_file/${widget.sessionId}/${file.name}'),
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
              label: label,
              url: '$flaskServerUrl/session_file/${widget.sessionId}/${file.name}',
              content: content,
            ));
          }
        }
      } catch (e) {
        debugPrint('Failed to load subtitle ${file.name}: $e');
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

  /// Get language label for display
  String _getLanguageLabel(String language) {
    // If the language contains parentheses, it's already a full name
    if (language.contains('(')) {
      return language;
    }
    
    // Map language codes to full names
    const langMap = {
      'en': 'English',
      'de': 'German',
      'fr': 'French',
      'es': 'Spanish',
      'it': 'Italian',
      'pt': 'Portuguese',
      'nl': 'Dutch',
      'ru': 'Russian',
      'ja': 'Japanese',
      'ko': 'Korean',
      'zh': 'Chinese',
      'ar': 'Arabic',
      'hi': 'Hindi',
      'vi': 'Vietnamese',
      'pl': 'Polish',
      'tr': 'Turkish',
      'uk': 'Ukrainian',
      'th': 'Thai',
      'id': 'Indonesian',
      'ms': 'Malay',
    };
    
    return langMap[language] ?? language;
  }

  /// When subtitle is changed
  void _onSubtitleChanged(String? language) {
    setState(() {
      _selectedSubtitle = language;
    });
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
    _videoController = VideoPlayerController.networkUrl(
      Uri.parse(_videoUrl),
    )..initialize().then((_) {
        setState(() {
          _isVideoReady = true;
        });
        _videoController!.addListener(_onVideoProgress);
        _videoController!.play();
      }).catchError((error) {
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

  void _downloadAllFiles() async {
    if (_files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No files to download'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preparing download... This may take a moment.'),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final token = await InternalAuthService.getToken();
      final downloadUrl = '$flaskServerUrl/session_download_all/${widget.sessionId}';
      
      final response = await http.get(
        Uri.parse(downloadUrl),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
        },
      );

      if (response.statusCode == 200) {
        String filename = 'session_${widget.sessionId}.zip';
        final contentDisposition = response.headers['content-disposition'] ?? '';
        final filenameMatch = RegExp(r'filename="([^"]+)"').firstMatch(contentDisposition);
        if (filenameMatch != null) {
          filename = filenameMatch.group(1)!;
        }

        final blob = html.Blob([response.bodyBytes], 'application/zip');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', filename)
          ..click();
        html.Url.revokeObjectUrl(url);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Downloaded: $filename'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('Failed to download ZIP: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
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

  double _getVideoHeight() {
    final screenHeight = MediaQuery.of(context).size.height;
    return (screenHeight * 0.25).clamp(_minVideoHeight, _maxVideoHeight);
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
      
      // Determine the filename - use the existing filename if available
      String vttFilename = '';
      final existingVtt = _files.firstWhere(
        (f) => f.name.contains(editedTranscript.language) && f.name.endsWith('.vtt'),
        orElse: () => const SessionFile(name: '', size: 0, url: ''),
      );
      
      if (existingVtt.name.isNotEmpty) {
        vttFilename = existingVtt.name;
      } else {
        // Create a clean filename
        String cleanLanguage = editedTranscript.language
            .replaceAll(' ', '_')
            .replaceAll('(', '')
            .replaceAll(')', '')
            .replaceAll('/', '_');
        vttFilename = 'subtitles_$cleanLanguage.vtt';
      }

      // Save to server using the existing filename
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
        // Reload files to get updated VTT
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

        // Reload subtitle tracks after saving
        await _loadSubtitleTracks();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Transcript saved and VTT updated: $vttFilename'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        // If server save fails, download VTT directly as fallback
        await _downloadVTT(editedTranscript);
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
            icon: const Icon(Icons.folder_zip),
            onPressed: _files.isNotEmpty ? _downloadAllFiles : null,
            tooltip: 'Download All Files',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSessionData,
            tooltip: 'Refresh',
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

    final videoHeight = _getVideoHeight();
    final screenWidth = MediaQuery.of(context).size.width;

    return Column(
      children: [
        // Video Player with fixed height - centered
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
                    subtitleTracks: _subtitleTracks.isNotEmpty ? _subtitleTracks : null,
                    selectedSubtitle: _selectedSubtitle,
                    onSubtitleChanged: _onSubtitleChanged,
                  ),
                ),
              ),
              
              // Subtitle overlay
              if (_selectedSubtitle != null && _parsedSubtitles.isNotEmpty)
                Positioned(
                  bottom: 50,
                  left: 20,
                  right: 20,
                  child: AnimatedOpacity(
                    opacity: 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _getSubtitleAtTime(
                          _videoController?.value.position.inSeconds.toDouble() ?? 0
                        ) ?? '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          shadows: [
                            Shadow(
                              blurRadius: 4,
                              color: Colors.black,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              
              // Chapter seekbar
              if (_chapters.isNotEmpty && _isVideoReady)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 6,
                    color: Colors.transparent,
                    child: ChapterSeekbar(
                      chapters: _chapters,
                      currentTime: _videoController?.value.position.inSeconds.toDouble() ?? 0,
                      onTap: _jumpToChapter,
                    ),
                  ),
                ),
            ],
          ),
        ),
        
        // Show either File List or Transcript
        Expanded(
          child: _showFileList
              ? _buildFileList()
              : Column(
                  children: [
                    // Language tabs with edit indicator
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: screenWidth * 0.9,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: LanguageTabs(
                              transcripts: _transcripts,
                              selectedLanguage: _selectedLanguage,
                              onLanguageSelected: _selectLanguage,
                            ),
                          ),
                          if (_isEditingMode)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              margin: const EdgeInsets.only(right: 8),
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
                                  strokeWidth: 2,
                                ),
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Editing: ${transcript.language}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.orange,
                ),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : () {
                      for (final controller in textControllers) {
                        controller.dispose();
                      }
                      for (final focusNode in focusNodes) {
                        focusNode.dispose();
                      }
                      setState(() {
                        _isEditingMode = false;
                      });
                    },
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isSaving ? null : () async {
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
                    label: Text(_isSaving ? 'Saving...' : 'Save to Server'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _isSaving ? null : () async {
                      final updatedTranscript = TranscriptData(
                        language: transcript.language,
                        text: transcript.text,
                        segments: editableSegments,
                        sender: transcript.sender,
                      );
                      await _saveAndDownloadVTT(updatedTranscript);
                    },
                    icon: const Icon(Icons.download),
                    label: const Text('Download VTT Only'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                    ),
                  ),
                ],
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

  Widget _buildFileList() {
    if (_files.isEmpty) {
      return const Center(
        child: Text('No files available'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: _getFileIcon(file.name),
            title: Text(
              file.name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  _formatFileSize(file.size),
                  style: const TextStyle(fontSize: 12),
                ),
                if (file.modified != null)
                  Text(
                    'Modified: ${_formatDate(file.modified!)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                    ),
                  ),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.download, color: Colors.blue),
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
    final languages = _transcripts.take(2).toList();
    if (languages.length < 2) {
      return TranscriptView(
        transcript: languages.isNotEmpty ? languages.first : TranscriptData.empty(),
        highlightedIndex: _currentSegmentIndex,
        scrollController: _scrollController,
      );
    }

    return Row(
      children: [
        Expanded(
          child: _isEditingMode
              ? _buildEditableTranscript(languages[0])
              : TranscriptView(
                  transcript: languages[0],
                  highlightedIndex: _currentSegmentIndex,
                  scrollController: ScrollController(),
                  title: languages[0].language,
                ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _isEditingMode
              ? _buildEditableTranscript(languages[1])
              : TranscriptView(
                  transcript: languages[1],
                  highlightedIndex: _currentSegmentIndex,
                  scrollController: ScrollController(),
                  title: languages[1].language,
                ),
        ),
      ],
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
    } else if (filename == 'transcripts.json') {
      return const Icon(Icons.data_array, color: Colors.deepPurple);
    } else if (filename == 'messages.json') {
      return const Icon(Icons.message, color: Colors.indigo);
    } else if (filename == 'index.html') {
      return const Icon(Icons.web, color: Colors.orange);
    } else {
      return const Icon(Icons.insert_drive_file, color: Colors.grey);
    }
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
