// session_output_screen.dart

import 'package:asr_live_translator/theme/responsive.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/models/session_data.dart';
import 'package:asr_live_translator/models/subtitle_track.dart';
import 'package:asr_live_translator/models/tts_track.dart';
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

enum SessionView { transcript, split, files }

/// Which TTS loading path the UI should use.
///
/// - [TtsPath.stream]  → backend URL, works offline once WAVs are local
/// - [TtsPath.signed]  → legacy: signed URL + bytes fallback
enum TtsPath { stream, signed }

// ─── TTS AUDIO SOURCE SELECTOR ─────────────────────────────────────
//
// Mirrors the "Audio source" <select> in the KIT archive page: lets
// the user swap the video's own audio for a synthesized TTS track in
// any of the translated languages. `null` means "Original audio".
class _TTSSelector extends StatelessWidget {
  final List<TTSTrack> tracks;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  const _TTSSelector({
    required this.tracks,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // Dedupe on the way in so a caller can never produce a broken menu.
    final unique = <String, TTSTrack>{};
    for (final t in tracks) {
      unique.putIfAbsent(t.label, () => t);
    }
    final dedupedTracks = unique.values.toList();

    final labels = dedupedTracks.map((t) => t.label).toSet();
    final safeValue =
        (selected != null && labels.contains(selected)) ? selected : null;

    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up, size: 16),
            SizedBox(width: 6),
            Text('Original audio'),
          ],
        ),
      ),
      ...dedupedTracks.map(
        (t) => DropdownMenuItem<String?>(
          value: t.label,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.graphic_eq, size: 16),
              const SizedBox(width: 6),
              Text(t.label),
            ],
          ),
        ),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: safeValue,
          items: items,
          onChanged: enabled ? onChanged : null,
          isDense: true,
          icon: const Icon(Icons.arrow_drop_down),
          style: const TextStyle(fontSize: 13, color: Colors.black87),
          selectedItemBuilder: (context) => items
              .map(
                (it) => Align(
                  alignment: Alignment.centerLeft,
                  child: it.child,
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SessionOutputScreenState extends State<SessionOutputScreen> {
  VideoPlayerController? _videoController;
  List<TranscriptData> _transcripts = [];
  final List<ChapterData> _chapters = [];
  List<SessionFile> _files = [];
  bool _isLoading = true;
  SessionView _view = SessionView.transcript;
  SessionView _lastNonFilesView = SessionView.transcript;
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
  // VTT cues so the overlay doesn't flicker on pause or boundary sits.
  String? _lastCueText;
  Map<String, List<VTTCue>> _parsedSubtitles = const {};
  // Last saved selection from the backend, or null if the user has
  // never picked. Drives the initial checkbox state in the dialog.
  List<String>? _embeddedLanguages;

  String? _selectedTts;                // label of the currently-selected track
  final AudioPlayer _ttsPlayer = AudioPlayer();   // package:audioplayers

  List<TTSTrack> _ttsTracks = <TTSTrack>[];
  
  List<TTSTrack> get ttsTracks => _ttsTracks;
  String? get selectedTts => _selectedTts;

  // Editing state. Owned by the State, not by build(), so
  // _buildEditableTranscript can be called on every rebuild without
  // leaking controllers.
  List<TextEditingController> _editTextControllers = [];
  List<FocusNode> _editFocusNodes = [];
  List<SegmentData> _editSegments = [];
  
  // Used by _downloadAllFiles to prevent double-tap.
  bool _isDownloadingAll = false;

  @override
  void initState() {
    super.initState();
    _loadSessionData();
  }

  @override
  void dispose() {
    _ttsPlayer.dispose();
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    _scrollController.dispose();
    _secondaryScrollController.dispose();
    _disposeEditControllers(); 
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  //  RESPONSIVE HELPERS
  // ─────────────────────────────────────────────────────────────
  //
  // Same breakpoints as session_detail_screen.dart, so the two screens
  // feel consistent when the user navigates between them:
  //   narrow   < 600 dp      (phones)
  //   medium   600 – 999 dp  (tablets, small windows)
  //   wide    ≥ 1000 dp      (desktop)

  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;

  /// Horizontal / vertical page padding. Was a hard-coded 16.
  double _pagePadding(BuildContext c) {
    if (_isNarrow(c)) return 12;
    if (MediaQuery.sizeOf(c).width < 1000) return 16;
    return 24;
  }

  /// Vertical gap between sections. Was a hard-coded 16.
  double _sectionGap(BuildContext c) {
    if (_isNarrow(c)) return 12;
    if (MediaQuery.sizeOf(c).width < 1000) return 16;
    return 24;
  }

  // ─── CUSTOM VTT PARSER ──────────────────────────────────────────────

  /// Parse VTT content into a list of VTTCue objects.
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
      final String line = lines[i].trim();

      if (line.isEmpty) continue;
      if (line.startsWith('WEBVTT')) continue;
      if (line.startsWith('Kind:')) continue;
      if (line.startsWith('Language:')) continue;

      if (line.contains('-->')) {
        // Save previous cue if exists.
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

        final parts = line.split('-->');
        if (parts.length == 2) {
          cueStart = _parseVTTTimestamp(parts[0].trim());
          cueEnd = _parseVTTTimestamp(parts[1].trim());
          inCue = true;
        }
      } else if (RegExp(r'^\d+$').hasMatch(line)) {
        // Cue index, skip.
        continue;
      } else if (inCue) {
        final speakerMatch =
            RegExp(r'<v\s+([^>]+)>([^<]*)</v>').firstMatch(line);
        if (speakerMatch != null) {
          speaker = speakerMatch.group(1)?.trim();
          final text = speakerMatch.group(2)?.trim() ?? '';
          if (text.isNotEmpty) {
            if (currentText.isNotEmpty) currentText += ' ';
            currentText += text;
          }
        } else {
          final cleanText =
              line.replaceAll(RegExp(r'<[^>]+>'), '').trim();
          if (cleanText.isNotEmpty) {
            if (currentText.isNotEmpty) currentText += ' ';
            currentText += cleanText;
          }
        }
      }
    }

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

  /// Parse VTT timestamp (00:00:00.000 or 00:00.000) to seconds.
  double _parseVTTTimestamp(String timestamp) {
    timestamp = timestamp.replaceAll(',', '.');
    final parts = timestamp.split(':');
    if (parts.length == 3) {
      final hours = double.tryParse(parts[0]) ?? 0;
      final minutes = double.tryParse(parts[1]) ?? 0;
      final seconds = double.tryParse(parts[2]) ?? 0;
      return hours * 3600 + minutes * 60 + seconds;
    } else if (parts.length == 2) {
      final minutes = double.tryParse(parts[0]) ?? 0;
      final seconds = double.tryParse(parts[1]) ?? 0;
      return minutes * 60 + seconds;
    }
    return 0.0;
  }

  /// Binary-search a sorted cue list for the cue that contains [time].
  /// Returns the cue's text, or null if [time] falls in a gap.
  String? _binarySearchCue(List<VTTCue> cues, double time) {
    int lo = 0;
    int hi = cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final cue = cues[mid];
      if (time < cue.start) {
        hi = mid - 1;
      } else if (time > cue.end) {
        lo = mid + 1;
      } else {
        return cue.text;
      }
    }
    return null;
  }

  /// Get subtitle text at a specific time.
    String? _getSubtitleAtTime(double time) {
    if (_selectedSubtitle == null) return null;
    final cues = _parsedSubtitles[_selectedSubtitle];
    if (cues == null || cues.isEmpty) return null;

    final found = _binarySearchCue(cues, time);
    if (found != null) {
      _lastCueText = found;
      return found;
    }
    return _lastCueText;
  }

  Future<void> _loadSubtitleTracks() async {
    final List<SubtitleTrack> newTracks = [];
    final Map<String, List<VTTCue>> newParsed = {};

    final allVttFiles = _files
        .where((f) => f.name.endsWith('.vtt') && f.name != 'subtitles.vtt')
        .toList();

    if (allVttFiles.isEmpty) {
      debugPrint('No VTT files found');
      return;
    }

    final Map<String, List<SessionFile>> languageFiles = {};
    for (final file in allVttFiles) {
      final language = _extractLanguageFromFilename(file.name);
      languageFiles.putIfAbsent(language, () => []).add(file);
    }

    final sortedLanguages = languageFiles.keys.toList()
      ..sort((a, b) {
        if (a.contains('Original') && !b.contains('Original')) return -1;
        if (!a.contains('Original') && b.contains('Original')) return 1;
        return a.compareTo(b);
      });

    final token = await InternalAuthService.getToken();

    for (final language in sortedLanguages) {
      final files = languageFiles[language]!;
      files.sort((a, b) => a.name.length.compareTo(b.name.length));

      for (final file in files) {
        try {
          final url = file.url.startsWith('http')
              ? file.url
              : '$flaskServerUrl${file.url}';

          debugPrint(
              'Loading subtitle for language "$language" from: $url');

          final response = await http.get(
            Uri.parse(url),
            headers: {'Authorization': 'Bearer ${token ?? ''}'},
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
              debugPrint(
                  'Loaded subtitle: ${file.name} (${cues.length} cues)');
              break;
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

  Future<void> _loadTTSTracks() async {
    final languages = _transcripts.map((t) => t.language).toList();
    final tracks = <TTSTrack>[];
    final seenLabels = <String>{};

    for (final lang in languages) {
      // KIT LT only serves TTS for real target languages. The speaker's own
      // ASR track ("Transcript") has no matching audio on the server.
      if (lang == 'Transcript' || lang.contains('Original ASR')) {
        continue;
      }
      final simple = _extractSimpleLanguage(lang);
      if (simple.isEmpty || simple == 'Unknown') continue;

      final label = '$simple Audio';
      if (!seenLabels.add(label)) continue;   // ← skip duplicates
      tracks.add(TTSTrack(
        label: label,
        url: '$flaskServerUrl/session-tts/${widget.sessionId}/'
            '${Uri.encodeComponent(label)}',
        language: simple,
      ));
    }

    setState(() {
      _ttsTracks = tracks;
      _selectedTts = null;
    });

    if (tracks.isNotEmpty) {
      // Defer to let the widget tree settle (context/dialog safety).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyTTSSource(tracks.first.label);
      });
    }
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
      _lastCueText = null;
    });
  }

  Future<void> _updateVideoSubtitles() async {
    // ── Step 1: choose which subtitle tracks to embed ──────────────
    // Same filter the old Save Subtitles dialog used: every VTT
    // except the generic "subtitles.vtt" alias (a duplicate of the
    // ASR track).
    final vttFiles = _files
        .where((f) => f.name.endsWith('.vtt') && f.name != 'subtitles.vtt')
        .toList();

    if (vttFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No subtitle files available to embed'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Seed the checkboxes from the last saved choice, if any.
    //   null      → never chosen → check everything
    //   []        → chosen none  → check nothing
    //   [a, b]    → check exactly those
    final previouslyChosen = _embeddedLanguages?.toSet();
    final selected = <String, bool>{
      for (final f in vttFiles)
        f.name: previouslyChosen == null || previouslyChosen.contains(f.name),
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedCount = selected.values.where((v) => v).length;
            final allSelected = selectedCount == vttFiles.length;

            return AlertDialog(
              title: const Text('Choose Subtitles to Embed'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select which subtitle tracks should be embedded '
                      'into video_subtitled.mp4:',
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            setDialogState(() {
                              for (final k in selected.keys) {
                                selected[k] = !allSelected;
                              }
                            });
                          },
                          child: Text(
                            allSelected ? 'Deselect all' : 'Select all',
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '$selectedCount / ${vttFiles.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: vttFiles.map((f) {
                            final language =
                                _extractLanguageFromFilename(f.name);
                            return CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              title: Text(
                                _getLanguageLabel(language),
                                style: const TextStyle(fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${f.name}  •  '
                                '${_formatFileSize(f.size)}',
                                style: const TextStyle(fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: selected[f.name] ?? false,
                              onChanged: (v) {
                                setDialogState(() {
                                  selected[f.name] = v ?? false;
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: selectedCount > 0
                      ? () => Navigator.pop(context, true)
                      : null,
                  icon: const Icon(Icons.video_settings),
                  label: Text('Embed ($selectedCount)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true) return;

    final selectedFilenames = vttFiles
        .where((f) => selected[f.name] == true)
        .map((f) => f.name)
        .toList();

    if (selectedFilenames.isEmpty) return;

    // ── Step 2: run the embed ──────────────────────────────────────
    setState(() => _isLoading = true);

    try {
      final token = await InternalAuthService.getToken();
      final url =
          '$flaskServerUrl/update-video-subtitles/${widget.sessionId}';

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'include': selectedFilenames}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final subtitleCount = data['embedded_subtitles']?.length ?? 0;
        final messagesUpdated = data['messages_updated'] ?? 0;

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '✅ ${data['message'] ?? 'Updated'}\n'
                'Embedded: $subtitleCount tracks, '
                'Updated: $messagesUpdated messages',
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 5),
            ),
          );
          await _loadSessionData();
        }
      } else if (response.statusCode == 423) {
        // Backend returns 423 when video_subtitled.mp4 is being played
        // in another tab and can't be replaced.
        String msg = 'Video is being played in another tab.';
        try {
          final data = jsonDecode(response.body);
          msg = data['message'] ?? msg;
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🔒 $msg'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 8),
            ),
          );
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
        setState(() => _isLoading = false);
      }
    }
  }
  // ─── END OF VTT PARSING ─────────────────────────────────────────────

  /// Trigger an explicit TTS backfill from the backend.
  ///
  /// The backend retries internally (4 attempts, 20 s apart) and skips
  /// files that already exist. It uses the per-session bearer token it
  /// stored when the session was created, so this works even after a
  /// backend restart and even for sessions uploaded by a different user
  /// (as long as KIT still has the WAVs).
  Future<void> _backfillTtsFiles() async {
    try {
      final token = await InternalAuthService.getToken();
      final url =
          '$flaskServerUrl/session-tts-backfill/${widget.sessionId}';

      final response = await http.post(
        Uri.parse(url),
        headers: {
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
          'TTS backfill: HTTP ${response.statusCode} — ${response.body}',
        );
        return;
      }

      final data = jsonDecode(response.body);
      final count = (data['count'] as num?)?.toInt() ?? 0;

      if (count > 0) {
        debugPrint('TTS backfill: downloaded $count file(s)');
        await _loadSessionData();
        await _loadTTSTracks();
      }
    } catch (e) {
      debugPrint('TTS backfill failed: $e');
    }
  }

  /// Fire-and-forget wrapper: only hits the backend when the local file
  /// list is missing TTS WAVs for a language we know KIT synthesises.
  ///
  /// Doesn't block the UI. Doesn't show a snackbar. Never throws.
  Future<void> _autoBackfillTtsIfNeeded() async {
    // Nothing to fetch if the dropdown wouldn't show any TTS options.
    if (_ttsTracks.isEmpty) return;

    // Already have every WAV we expect? Skip.
    final haveTts = _files.any(
      (f) => f.name.startsWith('tts_') && f.name.endsWith('.wav'),
    );
    if (haveTts) return;

    debugPrint('Auto-backfilling TTS files for ${widget.sessionId}');
    await _backfillTtsFiles();
  }


  Future<void> _loadSessionData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _isEditingMode = false;
    });

    try {
      final token = await InternalAuthService.getToken();

      final outputUrl =
          '$flaskServerUrl/session-output/${widget.sessionId}';
      final outputResponse = await http.get(
        Uri.parse(outputUrl),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
      );

      if (outputResponse.statusCode != 200) {
        setState(() {
          _errorMessage =
              'Failed to load session: ${outputResponse.statusCode}';
          _isLoading = false;
        });
        return;
      }

      final outputData = jsonDecode(outputResponse.body);
      final filesData = outputData['files'] as List? ?? [];
      _files = filesData.map((f) => SessionFile.fromJson(f)).toList();

      // Seed the dialog's initial checkbox state on the next open.
      _embeddedLanguages =
          (outputData['embedded_languages'] as List?)?.cast<String>();

      _files.sort((a, b) {
        if (a.modified == null && b.modified == null) return 0;
        if (a.modified == null) return 1;
        if (b.modified == null) return -1;
        return b.modified!.compareTo(a.modified!);
      });

      final transcriptUrl =
          '$flaskServerUrl/session-transcript-json/${widget.sessionId}';
      final transcriptResponse = await http.get(
        Uri.parse(transcriptUrl),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
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
        _videoUrl =
            '$flaskServerUrl/session-file/${widget.sessionId}/${videoFile.name}';
        _initializeVideoPlayer();
      }

      await _loadSubtitleTracks();
      await _loadTTSTracks();

      // NEW: pull TTS WAVs from the backend if this session doesn't
      // already have them locally. Best-effort; never blocks the UI.
      unawaited(_autoBackfillTtsIfNeeded());

      
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  /// Fire-and-forget: check if TTS files exist locally, and if not,
  /// trigger a background download. Doesn't block the UI.
  void _autoBackfillTtsIfNeeded() async {
    try {
      final token = await InternalAuthService.getToken();
      if (token == null || token.isEmpty) return;
      
      // Check if any TTS file is missing
      final url = '$flaskServerUrl/session-output/${widget.sessionId}';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      
      if (response.statusCode != 200) return;
      
      final data = jsonDecode(response.body);
      final files = (data['files'] as List?) ?? [];
      final hasTtsFiles = files.any((f) => 
          (f['name'] as String?)?.startsWith('tts_') == true);
      
      if (!hasTtsFiles && _ttsTracks.isNotEmpty) {
        debugPrint('Auto-backfilling TTS files...');
        await _autoBackfillTtsIfNeeded();
      }
    } catch (e) {
      debugPrint('Auto-backfill check failed: $e');
    }
  }


  void _extractChapters() {
    _chapters.clear();

    final transcript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty
          ? _transcripts.first
          : TranscriptData.empty(),
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
          (segment.markup == null ||
              segment.markup == 'paragraphBreak')) {
        final updatedSegments =
            List<SegmentData>.from(currentChapter.segments)..add(segment);
        currentChapter =
            currentChapter.copyWith(segments: updatedSegments);
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
    final old = _videoController;
    if (old != null) {
      old.removeListener(_onVideoProgress);
      old.dispose();
      _videoController = null;
    }

    _videoController = VideoPlayerController.networkUrl(
      Uri.parse(_videoUrl),
    )
      ..initialize().then((_) {
        if (!mounted) {
          _videoController?.dispose();
          _videoController = null;
          return;
        }
        setState(() => _isVideoReady = true);
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
    if (_videoController == null ||
        !_videoController!.value.isInitialized) {
      return;
    }

    final currentTime =
        _videoController!.value.position.inMilliseconds / 1000.0;

    final transcript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty
          ? _transcripts.first
          : TranscriptData.empty(),
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
      setState(() => _currentSegmentIndex = newIndex);
    }
  }

  void _setView(SessionView view) {
    setState(() {
      if (view != SessionView.files) {
        _lastNonFilesView = view;
      }
      _view = view;
    });
  }


  void _enterEditMode(TranscriptData transcript) {
    // Defensive: if a previous edit session is still around, clean it.
    _disposeEditControllers();

    _editSegments = List.from(transcript.segments);
    for (int i = 0; i < _editSegments.length; i++) {
      final c = TextEditingController(text: _editSegments[i].text);
      final index = i;
      c.addListener(() {
        _editSegments[index] =
            _copySegmentWithText(_editSegments[index], c.text);
      });
      _editTextControllers.add(c);
      _editFocusNodes.add(FocusNode());
    }

    setState(() {
      _isEditingMode = true;
    });
  }

  void _exitEditMode() {
    _disposeEditControllers();
    setState(() {
      _isEditingMode = false;
    });
  }

  /// Tear down controllers/focus nodes. Safe to call repeatedly.
  void _disposeEditControllers() {
    for (final c in _editTextControllers) {
      c.dispose();
    }
    for (final f in _editFocusNodes) {
      f.dispose();
    }
    _editTextControllers = [];
    _editFocusNodes = [];
    _editSegments = [];
  }

  void _selectLanguage(String language) {
    setState(() => _selectedLanguage = language);
    _extractChapters();
  }

  void _selectSecondaryLanguage(String language) {
    setState(() => _secondaryLanguage = language);
  }

  void _togglePlayPause() {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;

    if (c.value.isPlaying) {
      c.pause();
      if (_selectedTts != null) _ttsPlayer.pause();
    } else {
      c.play();
      if (_selectedTts != null) {
        _ttsPlayer.seek(c.value.position);
        _ttsPlayer.resume();
      }
    }
    setState(() {});
  }

  void _seekTo(double seconds) {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    _lastCueText = null;
    final target = Duration(milliseconds: (seconds * 1000).toInt());
    c.seekTo(target);
    if (_selectedTts != null) {
      _ttsPlayer.seek(target);
    }
  }

  /// Swap the audio source between the video's own track and a
  /// synthesized TTS track. Called by _TTSSelector.onChanged.
  static const int _maxTtsBytes = 30 * 1024 * 1024; // fallback cap only

  /// Original signed-URL + bytes-fallback path. Kept for reference and
  /// for the case where a future server variant only exposes the
  /// signed endpoint. Not called by default — see _applyTTSSource.
  Future<void> _applyTTSSourceSigned(String? label) async {
    final video = _videoController;

    await _ttsPlayer.stop();

    if (label == null) {
      setState(() => _selectedTts = null);
      await video?.setVolume(1.0);
      return;
    }

    // Safe lookup — no silent orElse fallback.
    TTSTrack? track;
    for (final t in _ttsTracks) {
      if (t.label == label) { track = t; break; }
    }
    if (track == null) {
      debugPrint('TTS label not found: $label');
      return;
    }

    try {
      await video?.setVolume(0.0);

      // 1) Streaming path first.
      final streamed = await _tryLoadViaSignedUrl(track);

      // 2) Fallback only if the signed endpoint isn't there.
      if (!streamed) {
        await _loadTtsAsBytes(track);
      }

      // 3) Shared tail: line the audio up with the video.
      if (video != null && video.value.isInitialized) {
        await _ttsPlayer.seek(video.value.position);
        if (video.value.isPlaying) await _ttsPlayer.resume();
      }
      setState(() => _selectedTts = label);
    } catch (e) {
      debugPrint('Failed to load TTS track "$label": $e');
      await video?.setVolume(1.0);
      if (mounted) {
        setState(() => _selectedTts = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load TTS audio: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Streams the TTS track straight from the backend URL.
  ///
  /// The backend now serves /session-tts/… from a local WAV when it has
  /// one, so this works offline with no token, no CORS preflight, and no
  /// in-memory size limit. When the WAV isn't local, the backend proxies
  /// KIT using the token it already cached — same URL, same call.
  Future<void> _applyTTSSourceStreaming(String? label) async {
    final video = _videoController;
    await _ttsPlayer.stop();

    if (label == null) {
      setState(() => _selectedTts = null);
      await video?.setVolume(1.0);
      return;
    }

    TTSTrack? track;
    for (final t in _ttsTracks) {
      if (t.label == label) { track = t; break; }
    }
    if (track == null) {
      debugPrint('TTS label not found: $label');
      return;
    }

    try {
      await video?.setVolume(0.0);

      // No Authorization header → no CORS preflight → no 30 MB ceiling.
      // Works whether the backend serves a local file or proxies KIT.
      // Explicitly declare the source as a WAV file
      await _ttsPlayer.play(UrlSource(track.url, mimeType: 'audio/wav'));

      if (video != null && video.value.isInitialized) {
        await _ttsPlayer.seek(video.value.position);
        if (video.value.isPlaying) await _ttsPlayer.resume();
      }
      setState(() => _selectedTts = label);
    } catch (e) {
      debugPrint('Failed to load TTS track "$label": $e');
      await video?.setVolume(1.0);
      if (mounted) {
        setState(() => _selectedTts = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to load TTS audio: $e')),
        );
      }
    }
  }


  /// Default path for TTS loading. Change this to TtsPath.signed to
  /// fall back to the old signed-URL/bytes behaviour without touching
  /// any other code.
  static const TtsPath _ttsPath = TtsPath.stream;

  /// Entry point for the TTS dropdown. Dispatches to the selected
  /// implementation so both remain available and neither is dead code.
  Future<void> _applyTTSSource(String? label) {
    switch (_ttsPath) {
      case TtsPath.stream:
        return _applyTTSSourceStreaming(label);
      case TtsPath.signed:
        return _applyTTSSourceSigned(label);
    }
  }

  /// Option B. Returns true if the audio source was set from a signed URL.
  /// Returns false *only* when the endpoint is missing — other failures throw
  /// so we don't silently mask a real problem behind the bytes fallback.
  Future<bool> _tryLoadViaSignedUrl(TTSTrack track) async {
    final token = await InternalAuthService.getToken();
    final signUri = Uri.parse(
      '$flaskServerUrl/session-tts-sign/${widget.sessionId}/'
      '${Uri.encodeComponent(track.label)}',
    );

    final resp = await http.get(
      signUri,
      headers: {'Authorization': 'Bearer ${token ?? ''}'},
    );

    // Endpoint not deployed → fall back.
    if (resp.statusCode == 404 || resp.statusCode == 501) {
      debugPrint('Signed TTS endpoint unavailable (HTTP ${resp.statusCode})');
      return false;
    }
    // Auth errors would hit the same wall on the fallback path — fail loudly.
    if (resp.statusCode != 200) {
      throw Exception('TTS sign failed: HTTP ${resp.statusCode}');
    }

    final signedPath = (jsonDecode(resp.body) as Map)['url'] as String;
    final signedUrl = signedPath.startsWith('http')
        ? signedPath
        : '$flaskServerUrl$signedPath';

    await _ttsPlayer.setSourceUrl(signedUrl);
    return true;
  }

  /// Option A. Full-bytes fallback with a size guard.
  Future<void> _loadTtsAsBytes(TTSTrack track) async {
    final token = await InternalAuthService.getToken();
    final uri = Uri.parse(track.url);
    final headers = {'Authorization': 'Bearer ${token ?? ''}'};

    // Ask for size first, if the server supports HEAD.
    int? declared;
    try {
      final head = await http.head(uri, headers: headers);
      declared = int.tryParse(head.headers['content-length'] ?? '');
    } catch (_) {/* HEAD unsupported — check after download instead */}

    if (declared != null && declared > _maxTtsBytes) {
      final ok = await _confirmLargeTts(declared);
      if (!ok) throw Exception('cancelled: track exceeds in-memory limit');
    }

    final resp = await http.get(uri, headers: headers);
    if (resp.statusCode != 200) {
      throw Exception('TTS fetch failed: HTTP ${resp.statusCode}');
    }

    if (declared == null && resp.bodyBytes.length > _maxTtsBytes) {
      throw Exception(
        'TTS is ${_humanBytes(resp.bodyBytes.length)}, exceeds '
        '${_humanBytes(_maxTtsBytes)} in-memory limit',
      );
    }

    await _ttsPlayer.setSourceBytes(resp.bodyBytes, mimeType: 'audio/wav');
  }

  Future<bool> _confirmLargeTts(int bytes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Large TTS track'),
        content: Text(
          'This track is ${_humanBytes(bytes)} and will be loaded fully '
          'into memory (streaming is unavailable). This can freeze the tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Load anyway'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  String _humanBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }


  void _jumpToChapter(ChapterData chapter) {
    if (_videoController == null ||
        !_videoController!.value.isInitialized) {
      return;
    }
    _videoController!
        .seekTo(Duration(milliseconds: (chapter.start * 1000).toInt()));
  }

  void _downloadFile(SessionFile file) async {
    try {
      final token = await InternalAuthService.getToken();
      final downloadUrl =
          '$flaskServerUrl/session-file/${widget.sessionId}/${file.name}';

      final response = await http.get(
        Uri.parse(downloadUrl),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
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
    if (_isDownloadingAll) return;

    setState(() => _isDownloadingAll = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preparing download… This may take a moment.'),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final token = await InternalAuthService.getToken();
      final encodedId = Uri.encodeComponent(widget.sessionId);
      final downloadUrl = '$flaskServerUrl/session-zip/$encodedId';

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

      String filename = 'session_${widget.sessionId}.zip';
      final cd = response.headers['content-disposition'] ?? '';
      final m = RegExp(r'filename\*?=(?:UTF-8'')?"?([^";]+)"?')
          .firstMatch(cd);
      if (m != null && m.group(1)!.trim().isNotEmpty) {
        filename = Uri.decodeComponent(m.group(1)!.trim());
      }
      filename = filename.replaceAll(RegExp(r'[\\/]'), '_');

      final blob = html.Blob([response.bodyBytes], 'application/zip');
      final url = html.Url.createObjectUrlFromBlob(blob);

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

  Map<String, dynamic> _segmentToJson(SegmentData segment) {
    return {
      'text': segment.text,
      'start': segment.start,
      'end': segment.end,
      'sender': segment.sender,
      if (segment.markup != null) 'markup': segment.markup,
      if (segment.words != null) 'words': segment.words,
      if (segment.wordId != null) 'word_id': segment.wordId,
      if (segment.sourceTokens != null)
        'source_tokens': segment.sourceTokens,
      if (segment.speakerName != null)
        'speaker_name': segment.speakerName,
      if (segment.refinedSentenceCluster != null)
        'refined_sentence_cluster': segment.refinedSentenceCluster,
      'unstable': segment.unstable,
      if (segment.messageId != null) 'message_id': segment.messageId,
    };
  }

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

  Future<void> _saveEditedTranscript(TranscriptData editedTranscript) async {
    setState(() => _isSaving = true);

    try {
      final token = await InternalAuthService.getToken();

      final index = _transcripts
          .indexWhere((t) => t.language == editedTranscript.language);

      if (index != -1) {
        _transcripts[index] = editedTranscript;
      }

      String vttFilename = '';

      final existingVtt = _files.firstWhere(
        (f) =>
            f.name.endsWith('.vtt') &&
            f.name != 'subtitles.vtt' &&
            (_extractLanguageFromFilename(f.name) ==
                    _extractLanguageFromFilename(
                        editedTranscript.language) ||
                f.name.contains(
                    _extractSimpleLanguage(editedTranscript.language))),
        orElse: () => const SessionFile(name: '', size: 0, url: ''),
      );

      if (existingVtt.name.isNotEmpty) {
        vttFilename = existingVtt.name;
      } else {
        final cleanLanguage =
            _extractSimpleLanguage(editedTranscript.language);
        vttFilename = 'subtitles_$cleanLanguage.vtt';
      }

      final saveUrl =
          '$flaskServerUrl/session-transcript-save-vtt/${widget.sessionId}';

      final requestBody = jsonEncode({
        'language': editedTranscript.language,
        'segments': editedTranscript.segments
            .map((s) => _segmentToJson(s))
            .toList(),
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

        if (responseData.containsKey('files')) {
          final filesData = responseData['files'] as List? ?? [];
          _files =
              filesData.map((f) => SessionFile.fromJson(f)).toList();
        } else {
          final outputUrl =
              '$flaskServerUrl/session-output/${widget.sessionId}';
          final outputResponse = await http.get(
            Uri.parse(outputUrl),
            headers: {'Authorization': 'Bearer ${token ?? ''}'},
          );

          if (outputResponse.statusCode == 200) {
            final outputData = jsonDecode(outputResponse.body);
            final filesData = outputData['files'] as List? ?? [];
            _files =
                filesData.map((f) => SessionFile.fromJson(f)).toList();
          }
        }

        await _loadSubtitleTracks();

        if (_selectedSubtitle != null) {
          final currentSubtitle = _selectedSubtitle;
          setState(() => _selectedSubtitle = null);
          await Future.delayed(const Duration(milliseconds: 100));
          setState(() => _selectedSubtitle = currentSubtitle);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '✅ Transcript saved and VTT updated: '
                  '${responseData['vtt_filename']}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception(
            'Failed to save transcript. Server returned: '
            '${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error saving transcript: $e');
      await _downloadVTT(editedTranscript);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
        _exitEditMode();                 // ← disposes + flips _isEditingMode
      }
    }
  }

  /// Extract simple language name (without parentheses or special characters).
  String _extractSimpleLanguage(String language) {
    final name = resolveLanguageName(language);
    return name.replaceAll(' ', '_');
  }

  /// Build an edited VTT blob and trigger a browser download for it.
  Future<void> _downloadVTT(TranscriptData transcript) async {
    try {
      final filename = '${transcript.language}_edited.vtt';
      final content = _generateVTTContent(transcript);

      final blob = html.Blob([content], 'text/vtt');
      final url = html.Url.createObjectUrlFromBlob(blob);

      final anchor = html.AnchorElement(href: url)
        ..download = filename
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();

      Future.delayed(const Duration(seconds: 1), () {
        html.Url.revokeObjectUrl(url);
      });

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

  Future<void> _downloadCurrentVtt() async {
    final TranscriptData transcript;

    if (_isEditingMode && _editSegments.isNotEmpty) {
      transcript = TranscriptData(
        language: _selectedLanguage,
        text: _editSegments.map((s) => s.text).join(' '),
        segments: List.from(_editSegments),
        sender: '',
      );
    } else {
      transcript = _transcripts.firstWhere(
        (t) => t.language == _selectedLanguage,
        orElse: () => _transcripts.isNotEmpty
            ? _transcripts.first
            : TranscriptData.empty(),
      );
    }

    await _downloadVTT(transcript);
  }

  String _generateVTTContent(TranscriptData transcript) {
    final buffer = StringBuffer();
    buffer.writeln('WEBVTT');
    buffer.writeln();

    int cueIndex = 0;
    for (final segment in transcript.segments) {
      if (segment.start == 0 && segment.end == 0) continue;
      if (segment.text.trim().isEmpty) continue;
      if (segment.markup == 'paragraphBreak') continue;
      if (segment.markup == 'chapterBreak') continue;
      if (segment.markup == 'heading') continue;

      cueIndex++;
      buffer.writeln('$cueIndex');

      final startTime = _formatVTTTimestamp(segment.start);
      final endTime = _formatVTTTimestamp(segment.end);
      buffer.writeln('$startTime --> $endTime');

      final cleanText =
          segment.text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (cleanText.isEmpty) continue;

      if (segment.speakerName != null &&
          segment.speakerName!.isNotEmpty) {
        final cleanSpeaker = segment.speakerName!
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
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

    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final currentTranscript = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.isNotEmpty
          ? _transcripts.first
          : TranscriptData.empty(),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Output'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              _view == SessionView.files
                  ? Icons.description
                  : Icons.folder,
            ),
            onPressed: () => _setView(
              _view == SessionView.files
                  ? _lastNonFilesView
                  : SessionView.files,
            ),
            tooltip: _view == SessionView.files
                ? 'Show Transcript'
                : 'Show Files',
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
            SizedBox(height: _sectionGap(context)),
            Text(_errorMessage, textAlign: TextAlign.center),
            SizedBox(height: _sectionGap(context)),
            ElevatedButton(
              onPressed: _loadSessionData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_transcripts.isEmpty && _files.isEmpty) {
      return const Center(child: Text('No data available'));
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
              if (_selectedSubtitle != null &&
                  _parsedSubtitles.isNotEmpty)
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

              // Chapter strip pinned to the bottom of the video pane.
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
          child: _view == SessionView.files
              ? _buildFileList()
              : Column(
                  children: [
                    // Language selector bar
                    Container(
                      constraints:
                          BoxConstraints(maxWidth: screenWidth * 0.9),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 4),
                      child: _view == SessionView.split
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
                          : Row(
                              children: [
                                LanguageSelector(
                                  transcripts: _transcripts,
                                  selectedLanguage: _selectedLanguage,
                                  onLanguageSelected: _selectLanguage,
                                  enabled: !_isEditingMode && !_isSaving,
                                ),
                                const SizedBox(width: 8),
                                if (!_isEditingMode && _ttsTracks.isNotEmpty)
                                  _TTSSelector(
                                    tracks: _ttsTracks,
                                    selected: _selectedTts,
                                    enabled: !_isSaving,
                                    onChanged: _applyTTSSource,
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
                                      borderRadius:
                                          BorderRadius.circular(4),
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
                      child: _view == SessionView.split
                          ? _buildSplitTranscriptView()
                          : _buildEditableTranscriptView(
                              currentTranscript,
                              currentTranscript,
                            ),
                    ),
                  ],
                ),
        ),

        // ─── Toolbar (bottom) ────────────────────────────────────────
        _buildToolbar(currentTranscript),
      ],
    );
  }

  Widget _buildEditableTranscriptView(
      TranscriptData transcript, TranscriptData currentTranscript) {
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
    // Controllers and segment list are owned by the State (see
    // _enterEditMode). build() only reads them, so a rebuild during
    // playback doesn't allocate anything new.
    final textControllers = _editTextControllers;
    final focusNodes = _editFocusNodes;
    final editableSegments = _editSegments;

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(_pagePadding(context)),
      itemCount: editableSegments.length,
      itemBuilder: (context, index) {
        final segment = editableSegments[index];
        final isHighlighted = index == _currentSegmentIndex;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: isHighlighted
                ? Colors.yellow.shade100
                : Colors.white,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isHighlighted
                  ? Colors.yellow.shade700
                  : Colors.grey.shade300,
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
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _formatTimestamp(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).toInt());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}.'
          '${millis.toString().padLeft(3, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}.'
          '${millis.toString().padLeft(3, '0')}';
    }
  }

  Widget _getFileIcon(String filename) {
    final r = Responsive.of(context);
    final size = r.iconLarge;
    if (filename.endsWith('.mp4') || filename.endsWith('.webm')) {
      return Icon(Icons.video_file, color: Colors.blue, size: size);
    } else if (filename.endsWith('.wav') ||
        filename.endsWith('.mp3')) {
      return Icon(Icons.audio_file, color: Colors.green, size: size);
    } else if (filename.endsWith('.vtt') ||
        filename.endsWith('.srt')) {
      return Icon(Icons.subtitles, color: Colors.orange, size: size);
    } else if (filename.endsWith('.html') ||
        filename.endsWith('.htm')) {
      return Icon(Icons.html, color: Colors.purple, size: size);
    } else if (filename.endsWith('.zip')) {
      return Icon(Icons.folder_zip, color: Colors.brown, size: size);
    } else if (filename.endsWith('.json')) {
      return Icon(Icons.code, color: Colors.teal, size: size);
    } else if (filename.endsWith('.rtf')) {
      return Icon(Icons.description, color: Colors.orange, size: size);
    } else if (filename.endsWith('.docx') ||
        filename.endsWith('.doc')) {
      return Icon(Icons.file_present, color: Colors.blue, size: size);
    } else if (filename.endsWith('.txt')) {
      return Icon(Icons.text_snippet, color: Colors.grey, size: size);
    } else if (filename == 'transcripts.json') {
      return Icon(Icons.data_array,
          color: Colors.deepPurple, size: size);
    } else if (filename == 'messages.json') {
      return Icon(Icons.message, color: Colors.indigo, size: size);
    } else if (filename == 'index.html') {
      return Icon(Icons.web, color: Colors.orange, size: size);
    } else {
      return Icon(Icons.insert_drive_file,
          color: Colors.grey, size: size);
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
      final dateTime = DateTime.parse(isoDate).toLocal();
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

      return '${dateTime.day.toString().padLeft(2, '0')}/'
          '${dateTime.month.toString().padLeft(2, '0')}/'
          '${dateTime.year} '
          '${dateTime.hour.toString().padLeft(2, '0')}:'
          '${dateTime.minute.toString().padLeft(2, '0')}';
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

    final left = _transcripts.firstWhere(
      (t) => t.language == _selectedLanguage,
      orElse: () => _transcripts.first,
    );
    final right = _transcripts.firstWhere(
      (t) => t.language == _secondaryLanguage,
      orElse: () =>
          _transcripts.length > 1 ? _transcripts[1] : _transcripts.first,
    );

    return Row(
      children: [
        Expanded(
          child: TranscriptView(
            transcript: left,
            highlightedIndex: _currentSegmentIndex,
            scrollController: _scrollController,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: TranscriptView(
                  transcript: right,
                  highlightedIndex: _currentSegmentIndex,
                  scrollController: _secondaryScrollController,
                ),
              ),
              // Close the second panel and go back to single view.
              Positioned(
                top: 4,
                right: 4,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _setView(SessionView.transcript),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }


  Widget _buildToolbar(TranscriptData currentTranscript) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: _isEditingMode
          ? _buildEditingToolbar(currentTranscript)
          : _buildNormalToolbar(currentTranscript),
    );
  }

  /// Cancel on the left, actions on the right. Only shown while the
  /// transcript editor is open.
  Widget _buildEditingToolbar(TranscriptData transcript) {
    return Row(
      children: [
        TextButton.icon(
          onPressed: _isSaving ? null : _exitEditMode,
          icon: const Icon(Icons.close, size: 18),
          label: const Text('Cancel'),
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _isSaving ? null : _downloadCurrentVtt,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Download VTT'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.blue,
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: _isSaving
              ? null
              : () async {
                  final updated = TranscriptData(
                    language: transcript.language,
                    text: transcript.text,
                    segments: _editSegments,
                    sender: transcript.sender,
                  );
                  await _saveEditedTranscript(updated);
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
              : const Icon(Icons.cloud_upload, size: 18),
          label: Text(_isSaving ? 'Saving…' : 'Save to Server'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  /// Default toolbar. The old SegmentedButton is replaced by a "+" that
  /// opens the second panel; the matching "×" lives on the second panel
  /// itself (see _buildSplitTranscriptView).
  Widget _buildNormalToolbar(TranscriptData currentTranscript) {
    final buttons = <Widget>[
      IconButton(
        icon: const Icon(Icons.edit),
        onPressed: currentTranscript.segments.isNotEmpty && !_isSaving
            ? () => _enterEditMode(currentTranscript)
            : null,
        tooltip: 'Edit Transcript',
      ),
      IconButton(
        icon: const Icon(Icons.download),
        onPressed: _showExportDialog,
        tooltip: 'Export Transcript',
      ),
      IconButton(
        icon: const Icon(Icons.subtitles),
        onPressed: _isSaving ? null : _downloadCurrentVtt,
        tooltip: 'Download VTT',
      ),
      const SizedBox(width: 12),
      Container(width: 1, height: 28, color: Colors.grey.shade300),
      const SizedBox(width: 12),
      if (_view == SessionView.transcript)
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _setView(SessionView.split),
          tooltip: 'Add second panel',
        )
      else
        const SizedBox(width: 48),
      const SizedBox(width: 12),
      Container(width: 1, height: 28, color: Colors.grey.shade300),
      const SizedBox(width: 12),
      IconButton(
        icon: const Icon(Icons.video_settings),
        onPressed: _updateVideoSubtitles,
        tooltip: 'Update Video Subtitles',
      ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: buttons),
    );
  }

}