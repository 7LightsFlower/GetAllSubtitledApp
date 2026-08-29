// session_output_screen.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/session_data.dart';
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

class _SessionOutputScreenState extends State<SessionOutputScreen> {
  VideoPlayerController? _videoController;
  List<TranscriptData> _transcripts = [];
  final List<ChapterData> _chapters = [];
  List<SessionFile> _files = [];
  bool _isLoading = true;
  bool _isSplitView = false;
  bool _showFileList = false;
  String _selectedLanguage = '';
  String _errorMessage = '';
  String _videoUrl = '';
  
  int _currentSegmentIndex = -1;
  final ScrollController _scrollController = ScrollController();
  bool _isVideoReady = false;

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

  Future<void> _loadSessionData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
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
        // For web
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
      // Use the endpoint that downloads from internal server first
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
                  ),
                ),
              ),
              
              // Chapter seekbar - thin overlay at the VERY BOTTOM
              // Only show if there are chapters and video is ready
              if (_chapters.isNotEmpty && _isVideoReady)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 6, // Very thin
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
                    // Language tabs
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: screenWidth * 0.9,
                      ),
                      child: LanguageTabs(
                        transcripts: _transcripts,
                        selectedLanguage: _selectedLanguage,
                        onLanguageSelected: _selectLanguage,
                      ),
                    ),
                    // Transcript view
                    Expanded(
                      child: _isSplitView
                          ? _buildSplitTranscriptView()
                          : TranscriptView(
                              transcript: currentTranscript,
                              highlightedIndex: _currentSegmentIndex,
                              scrollController: _scrollController,
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
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
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              _formatFileSize(file.size),
              style: const TextStyle(fontSize: 12),
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
          child: TranscriptView(
            transcript: languages[0],
            highlightedIndex: _currentSegmentIndex,
            scrollController: ScrollController(),
            title: languages[0].language,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: TranscriptView(
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
