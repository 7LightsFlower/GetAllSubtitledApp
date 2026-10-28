// working_screen.dart
import 'dart:async';

import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/screens/session_detail_screen.dart';
import 'package:asr_live_translator/screens/live_sessions_screen.dart';
import 'package:asr_live_translator/services/ui_mode.dart';
import 'package:asr_live_translator/widgets/server_connection_panel.dart';
import 'package:asr_live_translator/widgets/view_switcher.dart';
import 'package:asr_live_translator/theme/responsive.dart';
import 'package:asr_live_translator/widgets/job_progress_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http_parser/http_parser.dart';

// ─── Helper for robust date parsing ────────────────────────────
DateTime _parseDateTime(String dateStr) {
  // Try ISO 8601 first
  try {
    return DateTime.parse(dateStr).toLocal();
  } catch (_) {
    // KIT occasionally emits "+00:00Z" which Dart's parser rejects
    final cleaned = dateStr.replaceFirst(RegExp(r'\+00:00(?=Z)'), '');
    try {
      return DateTime.parse(cleaned).toLocal();
    } catch (_) {
      // As a last resort, treat it as epoch so it's obviously wrong
      // rather than masquerading as "just now".
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}

// ─── Data model ──────────────────────────────────────────────────
class VideoProject {
  final String key;
  final String name;
  final String fileName;
  final DateTime uploaded;
  final DateTime? lastOpened;
  final double duration;
  final double fps;
  final String codec;
  final int fileSize;
  final int segmentCount;
  final List<String> languages;
  final String? thumbnailUrl;
  final bool segmentationDone;
  final int segmentationProgress;

  // Green-screen prep state. Populated by the backend's
  // /videos response; defaults keep older servers working.
  final String? greenscreenFileName;
  final String greenscreenStatus;   // pending | building | ready | failed
  final int greenscreenProgress;    // 0..100
  final String source;

  /// Folder on the working screen (null = unsorted). Mutable so a move
  /// can update the card immediately.
  String? folder;

  VideoProject({
    required this.key,
    required this.name,
    required this.fileName,
    required this.uploaded,
    this.lastOpened,
    required this.duration,
    required this.fps,
    required this.codec,
    required this.fileSize,
    required this.segmentCount,
    required this.languages,
    this.thumbnailUrl,
    required this.segmentationDone,
    required this.segmentationProgress,
    required this.greenscreenFileName,
    required this.greenscreenStatus,
    required this.greenscreenProgress,
    required this.source,
    this.folder,
  });

  factory VideoProject.fromJson(Map<String, dynamic> json) {
    return VideoProject(
      key: json['key'] as String? ??
          'fallback-${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Untitled',
      fileName: json['file_name'] as String? ?? 'video.mp4',
      uploaded: json['uploaded'] != null
          ? _parseDateTime(json['uploaded'] as String)
          : DateTime.now(),
      lastOpened: json['last_opened'] != null
          ? _parseDateTime(json['last_opened'] as String)
          : null,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      codec:  json['codec']  as String? ?? '',
      fileSize: json['file_size'] as int? ?? 0,
      segmentCount: json['segment_count'] as int? ?? 0,
      languages: (json['languages'] as List?)?.cast<String>() ?? [],
      thumbnailUrl: json['thumbnail_url'] as String?,
      segmentationDone: json['segmentation_done'] as bool? ?? false,
      segmentationProgress: json['segmentation_progress'] as int? ?? 0,
      greenscreenFileName: json['greenscreen_file_name'] as String?,
      greenscreenStatus:
          json['greenscreen_status'] as String? ?? 'pending',
      greenscreenProgress: json['greenscreen_progress'] as int? ?? 0,
      source: json['source'] as String? ?? 'Desktop Upload',
      folder: (json['folder'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['folder'] as String).trim(),
    );
  }
}

// ─── Import status enums and classes ────────────────────────────
enum ImportState { pending, downloading, completed, error }

class ImportVideoStatus {
  final String url;
  ImportState state;
  String message;
  double progress;

  ImportVideoStatus({
    required this.url,
    this.state = ImportState.pending,
    this.message = 'Pending',
    this.progress = 0.0,
  });
}

// ─── Main screen ────────────────────────────────────────────────
class WorkingScreen extends StatefulWidget {
  const WorkingScreen({super.key});

  @override
  State<WorkingScreen> createState() => _WorkingScreenState();
}

class _WorkingScreenState extends State<WorkingScreen>
    with UiModeListener<WorkingScreen> {
  List<VideoProject> _projects = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _sortMode = 'newest';
  double _storageUsed = 0.0;
  double _storageLimit = 50.0;
  String? _listError;

  // Track which project keys already had the trigger fired, so we
  // don't spam the backend on every refresh.
  final Set<String> _greenscreenTriggered = {};

  // ─── Lifecycle ────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _registerDropZone();
    _updateWorkingScreenUrl();
    _fetchProjects();
    _loadTab();
    // Re-run once the token is known, in case the first call raced
    // ahead of _checkConnection().
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _updateWorkingScreenUrl();
    });
  }

  @override
  void dispose() {
    _unregisterDropZone();
    super.dispose();
  }

  // ─── Drag & drop upload (from Windows Explorer / Finder) ────────
  // Uses the browser's own drag events on the whole page. A dropped
  // video goes through the same chunked upload as "From this device".
  static const _videoExtensions = {
    'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v', 'mpg', 'mpeg', 'wmv', 'flv',
    '3gp', 'ts', 'mts', 'm2ts', 'ogv',
  };
  int _dragDepth = 0; // dragenter/dragleave fire for every child element
  bool _isDraggingFile = false;
  bool _dropBusy = false;
  JSFunction? _onDragEnter, _onDragOver, _onDragLeave, _onDrop;

  bool _hasFiles(web.DragEvent e) {
    final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
    return types.any((t) => t.toDart == 'Files');
  }

  /// Only the visible page reacts; a pushed screen on top stays untouched.
  bool get _isTopRoute => mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  void _registerDropZone() {
    _onDragEnter = ((web.DragEvent e) {
      if (!_hasFiles(e)) return;
      e.preventDefault();
      _dragDepth++;
      if (_isTopRoute && !_isDraggingFile) setState(() => _isDraggingFile = true);
    }).toJS;
    _onDragOver = ((web.DragEvent e) {
      if (!_hasFiles(e)) return;
      // Without preventDefault the browser would open the file itself.
      e.preventDefault();
      e.dataTransfer?.dropEffect = _isTopRoute ? 'copy' : 'none';
    }).toJS;
    _onDragLeave = ((web.DragEvent e) {
      if (!_hasFiles(e)) return;
      if (_dragDepth > 0) _dragDepth--;
      if (_dragDepth == 0 && _isDraggingFile && mounted) {
        setState(() => _isDraggingFile = false);
      }
    }).toJS;
    _onDrop = ((web.DragEvent e) {
      if (!_hasFiles(e)) return;
      e.preventDefault();
      _dragDepth = 0;
      if (mounted && _isDraggingFile) setState(() => _isDraggingFile = false);
      if (!_isTopRoute) return;
      final list = e.dataTransfer?.files;
      if (list == null) return;
      final files = <web.File>[
        for (var i = 0; i < list.length; i++)
          if (list.item(i) != null) list.item(i)!,
      ];
      _uploadDroppedFiles(files);
    }).toJS;

    web.document
      ..addEventListener('dragenter', _onDragEnter)
      ..addEventListener('dragover', _onDragOver)
      ..addEventListener('dragleave', _onDragLeave)
      ..addEventListener('drop', _onDrop);
  }

  void _unregisterDropZone() {
    web.document
      ..removeEventListener('dragenter', _onDragEnter)
      ..removeEventListener('dragover', _onDragOver)
      ..removeEventListener('dragleave', _onDragLeave)
      ..removeEventListener('drop', _onDrop);
  }

  bool _looksLikeVideo(web.File f) {
    if (f.type.startsWith('video/')) return true;
    final dot = f.name.lastIndexOf('.');
    return dot > 0 && _videoExtensions.contains(f.name.substring(dot + 1).toLowerCase());
  }

  Future<void> _uploadDroppedFiles(List<web.File> files) async {
    if (_dropBusy) {
      _showSnackBar('Please wait until the current upload has finished.',
          isError: true);
      return;
    }
    final videos = files.where(_looksLikeVideo).toList();
    final skipped = files.length - videos.length;
    if (videos.isEmpty) {
      _showSnackBar(
        files.length == 1
            ? '"${files.first.name}" is not a video file.'
            : 'None of the dropped files is a video.',
        isError: true,
      );
      return;
    }
    if (skipped > 0) {
      _showSnackBar('$skipped non-video file(s) skipped.', isError: true);
    }

    if (_showLive) await _setTab(false); // uploads belong to the video list
    _dropBusy = true;
    try {
      // One after another, each with the usual upload dialog.
      for (final f in videos) {
        if (!mounted) return;
        final buffer = await f.arrayBuffer().toDart;
        final bytes = buffer.toDart.asUint8List();
        if (!mounted) return;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => _UploadDialog(
            bytes: bytes,
            fileName: f.name,
            mode: UploadMode.chunked,
            onUploadComplete: _fetchProjects,
          ),
        );
      }
    } catch (e) {
      _showSnackBar('Could not read the dropped file: $e', isError: true);
    } finally {
      _dropBusy = false;
    }
  }

  /// Page body with the "drop video here" overlay while dragging a file.
  Widget _withDropZone(Widget child) {
    return Stack(
      children: [
        child,
        if (_isDraggingFile)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.blue.shade400, width: 3),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(blurRadius: 16, color: Colors.black26),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_upload_outlined,
                            size: 48, color: Colors.blue.shade600),
                        const SizedBox(height: 8),
                        const Text(
                          'Drop video to upload',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'MP4, MOV, MKV, WebM, AVI … — several at once is fine',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Folders ────────────────────────────────────────────────
  // One level of folders, stored on the backend (/api/folders). The bar
  // above the grid filters by folder; cards are moved by dragging them
  // onto a folder, or with the folder button / long-press menu.
  static const String _unsortedFilter = '\u0000unsorted';
  static const String _folderFilterPref = 'working_folder_filter';
  List<String> _folders = [];
  String? _folderFilter; // null = all videos, _unsortedFilter, or a name
  String? _dropHover;    // folder chip currently under a dragged card

  // ─── Videos / Live sessions switcher ─────────────────────────
  static const String _tabPref = 'working_tab';
  bool _showLive = false;
  int _liveReload = 0;

  Future<void> _loadTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final live = prefs.getString(_tabPref) == 'live';
      if (mounted && live != _showLive) setState(() => _showLive = live);
    } catch (_) {}
  }

  Future<void> _setTab(bool live) async {
    if (live == _showLive) return;
    setState(() => _showLive = live);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tabPref, live ? 'live' : 'videos');
    } catch (_) {}
    if (!live) _fetchProjects(); // pick up anything new
  }

  Widget _buildTabSwitcher(Responsive r) {
    return ViewSwitcher(
      options: const [
        ViewSwitcherOption(
          icon: Icons.video_library_outlined,
          label: 'Video list',
          shortLabel: 'Videos',
        ),
        ViewSwitcherOption(
          icon: Icons.mic_none,
          label: 'Live transcripts',
          shortLabel: 'Live',
        ),
      ],
      selected: _showLive ? 1 : 0,
      onChanged: (i) => _setTab(i == 1),
    );
  }

  /// Same page padding as the Live transcripts list, so the switcher,
  /// the big action button and the search field sit at the same place
  /// in both views.
  double _pagePad(BuildContext c) =>
      MediaQuery.sizeOf(c).width < 600 ? 12 : 24;

  Future<void> _fetchFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_folderFilterPref);
      final resp = await http
          .get(Uri.parse('$authBaseUrl/api/folders'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || !mounted) return;
      final list = ((jsonDecode(resp.body) as Map)['folders'] as List? ?? [])
          .map((e) => e.toString())
          .toList();
      setState(() {
        _folders = list;
        if (_folderFilter == null && saved != null && saved.isNotEmpty) {
          _folderFilter = saved;
        }
        if (_folderFilter != null &&
            _folderFilter != _unsortedFilter &&
            !_folders.contains(_folderFilter)) {
          _folderFilter = null;
        }
      });
    } catch (e) {
      debugPrint('loading folders failed: $e');
    }
  }

  Future<void> _setFolderFilter(String? value) async {
    setState(() => _folderFilter = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_folderFilterPref);
      } else {
        await prefs.setString(_folderFilterPref, value);
      }
    } catch (_) {}
  }

  Future<String?> _askFolderName({String title = 'New folder', String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The controller is left to the GC: disposing it here would race the
    // dialog's closing animation, which still reads it.
  }

  String _apiError(http.Response r) {
    try {
      final b = jsonDecode(r.body);
      if (b is Map && b['error'] != null) return b['error'].toString();
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }

  Future<void> _createFolder() async {
    final name = await _askFolderName();
    if (name == null || name.isEmpty) return;
    try {
      final r = await http.post(
        Uri.parse('$authBaseUrl/api/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      );
      if (r.statusCode == 201) {
        await _fetchFolders();
        _setFolderFilter(name);
      } else {
        _showSnackBar(_apiError(r), isError: true);
      }
    } catch (e) {
      _showSnackBar('Could not create folder: $e', isError: true);
    }
  }

  Future<void> _renameFolder(String oldName) async {
    final name = await _askFolderName(title: 'Rename folder', initial: oldName);
    if (name == null || name.isEmpty || name == oldName) return;
    try {
      final r = await http.put(
        Uri.parse('$authBaseUrl/api/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'old': oldName, 'new': name}),
      );
      if (r.statusCode != 200) {
        _showSnackBar(_apiError(r), isError: true);
        return;
      }
      setState(() {
        for (final p in _projects) {
          if (p.folder == oldName) p.folder = name;
        }
      });
      await _fetchFolders();
      _setFolderFilter(name);
    } catch (e) {
      _showSnackBar('Could not rename folder: $e', isError: true);
    }
  }

  Future<void> _deleteFolder(String name) async {
    final count = _projects.where((p) => p.folder == name).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete folder?'),
        content: Text(count == 0
            ? 'The folder "$name" is empty.'
            : 'The $count video(s) in "$name" are not deleted — they move '
                'to "Unsorted".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete folder'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await http.delete(
          Uri.parse('$authBaseUrl/api/folders?name=${Uri.encodeQueryComponent(name)}'));
      if (r.statusCode != 200) {
        _showSnackBar(_apiError(r), isError: true);
        return;
      }
      setState(() {
        for (final p in _projects) {
          if (p.folder == name) p.folder = null;
        }
      });
      await _fetchFolders();
      _setFolderFilter(null);
    } catch (e) {
      _showSnackBar('Could not delete folder: $e', isError: true);
    }
  }

  Future<void> _moveToFolder(VideoProject project, String? folder) async {
    if (project.folder == folder) return;
    final before = project.folder;
    setState(() => project.folder = folder); // immediate
    try {
      final r = await http.post(
        Uri.parse('$authBaseUrl/api/videos/${Uri.encodeComponent(project.key)}/folder'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folder': folder}),
      );
      if (r.statusCode != 200) {
        setState(() => project.folder = before);
        _showSnackBar(_apiError(r), isError: true);
        return;
      }
      if (folder != null && !_folders.contains(folder)) await _fetchFolders();
      _showSnackBar(folder == null
          ? '"${project.name}" moved to Unsorted'
          : '"${project.name}" moved to "$folder"');
    } catch (e) {
      setState(() => project.folder = before);
      _showSnackBar('Could not move video: $e', isError: true);
    }
  }

  Future<void> _pickFolderFor(VideoProject project) async {
    const newFolder = '\u0000new';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move "${project.name}" to'),
        children: [
          for (final f in _folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Row(children: [
                Icon(project.folder == f ? Icons.folder : Icons.folder_outlined,
                    size: 20, color: Colors.amber.shade800),
                const SizedBox(width: 10),
                Expanded(child: Text(f, overflow: TextOverflow.ellipsis)),
                if (project.folder == f) const Icon(Icons.check, size: 18),
              ]),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _unsortedFilter),
            child: Row(children: [
              const Icon(Icons.inbox_outlined, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Text('Unsorted (no folder)')),
              if (project.folder == null) const Icon(Icons.check, size: 18),
            ]),
          ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, newFolder),
            child: const Row(children: [
              Icon(Icons.create_new_folder_outlined, size: 20, color: Colors.blue),
              SizedBox(width: 10),
              Text('New folder…', style: TextStyle(color: Colors.blue)),
            ]),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == newFolder) {
      final name = await _askFolderName();
      if (name == null || name.isEmpty) return;
      await _moveToFolder(project, name);
      return;
    }
    await _moveToFolder(project, choice == _unsortedFilter ? null : choice);
  }

  /// "All videos · Unsorted · folders…" bar. Folder chips accept dragged
  /// video cards.
  Widget _buildFolderBar(Responsive r) {
    final unsortedCount = _projects.where((p) => p.folder == null).length;

    Widget chip({
      required String label,
      required int count,
      required bool selected,
      required IconData icon,
      required VoidCallback onTap,
      String? dropKey, // folder name, _unsortedFilter, or null = no drop
    }) {
      Widget c(bool hover) => ChoiceChip(
            avatar: Icon(icon,
                size: 18,
                color: hover ? Colors.white : Colors.amber.shade800),
            label: Text('$label · $count'),
            selected: selected || hover,
            selectedColor: hover ? Colors.blue : null,
            labelStyle: hover ? const TextStyle(color: Colors.white) : null,
            onSelected: (_) => onTap(),
            visualDensity: VisualDensity.compact,
          );
      if (dropKey == null) return c(false);
      return DragTarget<String>(
        onWillAcceptWithDetails: (_) {
          setState(() => _dropHover = dropKey);
          return true;
        },
        onLeave: (_) => setState(() => _dropHover = null),
        onAcceptWithDetails: (d) {
          setState(() => _dropHover = null);
          final project = _projects.where((p) => p.key == d.data).firstOrNull;
          if (project != null) {
            _moveToFolder(project, dropKey == _unsortedFilter ? null : dropKey);
          }
        },
        builder: (_, __, ___) => c(_dropHover == dropKey),
      );
    }

    final selectedFolder = (_folderFilter != null && _folderFilter != _unsortedFilter)
        ? _folderFilter
        : null;

    return Wrap(
      spacing: r.spaceS,
      runSpacing: r.spaceXS,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        chip(
          label: 'All videos',
          count: _projects.length,
          selected: _folderFilter == null,
          icon: Icons.video_library_outlined,
          onTap: () => _setFolderFilter(null),
        ),
        chip(
          label: 'Unsorted',
          count: unsortedCount,
          selected: _folderFilter == _unsortedFilter,
          icon: Icons.inbox_outlined,
          onTap: () => _setFolderFilter(_unsortedFilter),
          dropKey: _unsortedFilter,
        ),
        for (final f in _folders)
          chip(
            label: f,
            count: _projects.where((p) => p.folder == f).length,
            selected: _folderFilter == f,
            icon: _folderFilter == f ? Icons.folder : Icons.folder_outlined,
            onTap: () => _setFolderFilter(f),
            dropKey: f,
          ),
        ActionChip(
          avatar: const Icon(Icons.create_new_folder_outlined, size: 18),
          label: const Text('New folder'),
          onPressed: _createFolder,
          visualDensity: VisualDensity.compact,
        ),
        if (selectedFolder != null) ...[
          TextButton.icon(
            onPressed: () => _renameFolder(selectedFolder),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Rename'),
          ),
          TextButton.icon(
            onPressed: () => _deleteFolder(selectedFolder),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Delete folder'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ],
    );
  }

  Future<void> _fetchProjects() async {
    if (!mounted) return;
    _fetchFolders();
    setState(() {
      _isLoading = true;
      _listError = null;
    });

    final url = Uri.parse('$authBaseUrl/videos');

    debugPrint('📡 GET $url  (authBaseUrl="$authBaseUrl")');

    http.Response response;
    try {
      response = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      debugPrint('❌ Timed out after 15 s');
      if (mounted) {
        setState(() {
          _listError =
              'The backend did not respond within 15 seconds. '
              'Make sure the Flask server is running on port 5000.';
          _isLoading = false;
        });
      }
      return;
    } on http.ClientException catch (e) {
      debugPrint('❌ ClientException: $e');
      if (mounted) {
        setState(() {
          _listError =
              'Cannot reach the backend at $authBaseUrl.\n\n'
              'Check that the Flask server is running and that the URL '
              'in constants.dart is correct.';
          _isLoading = false;
        });
      }
      return;
    } catch (e) {
      debugPrint('❌ Unexpected network error: $e');
      if (mounted) {
        setState(() {
          _listError = 'Network error while loading projects: $e';
          _isLoading = false;
        });
      }
      return;
    }

    // ── Check the response before parsing it. ──
    final contentType = response.headers['content-type'] ?? '';
    final bodyPreview = response.body.length > 200
        ? response.body.substring(0, 200)
        : response.body;

    debugPrint('📡 status=${response.statusCode} content-type=$contentType');
    debugPrint('📡 body preview: $bodyPreview');

    if (response.statusCode != 200) {
      if (mounted) {
        setState(() {
          _listError =
              'Backend returned HTTP ${response.statusCode}.\n\n'
              '${_shorten(bodyPreview, 200)}';
          _isLoading = false;
        });
      }
      return;
    }

    if (!contentType.contains('application/json') &&
        bodyPreview.trimLeft().startsWith('<')) {
      debugPrint('❌ Got HTML instead of JSON — wrong URL?');

      if (mounted) {
        setState(() {
          _listError =
              'The URL "$authBaseUrl/videos" returned an HTML page, not '
              'JSON. This usually means authBaseUrl is pointing at the '
              'web host instead of the Flask backend.\n\n'
              'Fix: set authBaseUrl to your Flask server, e.g. '
              '"http://localhost:5000" when running locally.';
          _isLoading = false;
        });
      }
      return;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('❌ JSON parse failed: $e');
      if (mounted) {
        setState(() {
          _listError =
              'The backend returned something that is not valid JSON.\n\n'
              '${_shorten(bodyPreview, 200)}';
          _isLoading = false;
        });
      }
      return;
    }

    final projects = (data['projects'] as List?)
            ?.map((e) {
              try {
                return VideoProject.fromJson(e as Map<String, dynamic>);
              } catch (err) {
                debugPrint('❌ Error parsing project: $err');
                return null;
              }
            })
            .whereType<VideoProject>()
            .toList() ??
        [];

    if (!mounted) return;
    setState(() {
      _projects = projects;
      _storageUsed =
          (data['storage_used_gb'] as num?)?.toDouble() ?? 0.0;
      _storageLimit =
          (data['storage_limit_gb'] as num?)?.toDouble() ?? 50.0;
      _isLoading = false;
    });

    // Fire-and-forget: ask the backend to prepare a green-screen for
    // any project that still needs one. The server answers immediately
    // (202) and does the work in a background thread.
    _triggerGreenscreenForPendingProjects();
  }

  /// Reflect the fact that we are on the working screen in the browser
  /// URL bar.
  ///
  /// Called on entry and every time the user pops back from a sub-screen
  /// (session detail, enhancement, …). Keeps the URL meaningful when many
  /// videos are listed here, instead of leaving the last-opened video's
  /// key in the bar.
  Future<void> _updateWorkingScreenUrl() async {
    try {
      final email = await _currentUserEmail();
      final path = email.isNotEmpty
          ? '/working/${Uri.encodeComponent(email)}'
          : '/working';
      if (web.window.location.pathname != path) {
        web.window.history.replaceState(
          null,
          'Working Screen',
          path,
        );
      }
    } catch (e) {
      debugPrint('working-screen url update failed: $e');
    }
  }

  /// Email the backend reports for the current request.
  ///
  /// Asks `/whoami` rather than parsing the token locally, so a change
  /// in the KIT token format doesn't silently produce a wrong URL.
  /// Returns an empty string on any failure; callers fall back to a
  /// generic `/working` path.
  Future<String> _currentUserEmail() async {
    try {
      final token = await InternalAuthService.getToken();
      final resp = await http
          .get(
            Uri.parse('$flaskServerUrl/whoami'),
            headers: {
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return '';
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final email = (body['email'] ?? '').toString().trim();
      return email;
    } catch (e) {
      debugPrint('whoami failed: $e');
      return '';
    }
  }

  Future<void> _triggerGreenscreenForPendingProjects() async {
    final toTrigger = _projects
        .where((p) => _projectNeedsGreenscreen(p))
        .where((p) => !_greenscreenTriggered.contains(p.key))
        .toList();

    if (toTrigger.isEmpty) return;

    for (final p in toTrigger) {
      _greenscreenTriggered.add(p.key);
      try {
        await http.post(
          Uri.parse('$authBaseUrl/prepare-greenscreen/${p.key}'),
          headers: {'Content-Type': 'application/json'},
        );
        debugPrint('🧪 prepare-greenscreen requested for ${p.key}');
      } catch (e) {
        // If the request itself fails, allow a retry on the next
        // refresh by forgetting the key.
        _greenscreenTriggered.remove(p.key);
        debugPrint('prepare-greenscreen failed for ${p.key}: $e');
      }
    }

    // Single refresh after a short delay. The server does the heavy
    // lifting; we just need the UI to catch up on the new status.
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) _fetchProjects();
    });
  }

  bool _projectNeedsGreenscreen(VideoProject p) {
    final s = p.greenscreenStatus;
    return s == 'pending' || s == 'failed';
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  String _shorten(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }

  void _showBackendHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline),
            SizedBox(width: 8),
            Text('How to fix this'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('1. Start the backend server:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  'cd GetAllSubtitledApp/lib\n'
                  'python backend.py',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text('2. Confirm the URL in constants.dart:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  "const String authBaseUrl    = 'http://localhost:5000';\n"
                  "const String flaskServerUrl = 'http://localhost:5000';",
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text('3. Test from a terminal:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const SelectableText(
                  'curl http://localhost:5000/videos\n'
                  '# should print JSON, not HTML',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  'Current authBaseUrl: "$authBaseUrl"',
                  style: const TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ─── YouTube URL detection and extraction ─────────────────────
  bool _isYouTubeUrl(String url) {
    final youtubePatterns = [
      r'youtube\.com/watch\?v=',
      r'youtu\.be/',
      r'youtube\.com/shorts/',
      r'youtube\.com/embed/',
      r'youtube\.com/v/',
      r'youtube\.com/e/',
      r'm\.youtube\.com/',
    ];
    final lowerUrl = url.toLowerCase();
    return youtubePatterns.any((pattern) => lowerUrl.contains(pattern));
  }

  String _extractYouTubeVideoId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/watch\?v=([^&]+)'),
      RegExp(r'youtu\.be/([^?]+)'),
      RegExp(r'youtube\.com/shorts/([^?]+)'),
      RegExp(r'youtube\.com/embed/([^?]+)'),
      RegExp(r'youtube\.com/v/([^?]+)'),
      RegExp(r'youtube\.com/e/([^?]+)'),
      RegExp(r'm\.youtube\.com/watch\?v=([^&]+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) {
        return match.group(1)!;
      }
    }

    return '';
  }

  Future<String?> _getYouTubeVideoUrl(String youtubeUrl) async {
    try {
      final videoId = _extractYouTubeVideoId(youtubeUrl);
      if (videoId.isEmpty) {
        throw Exception('Could not extract video ID from YouTube URL');
      }

      final serverUrl = '$flaskServerUrl/api/youtube-info';

      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': youtubeUrl}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['url'] != null) {
          return data['url'];
        } else {
          throw Exception(data['error'] ?? 'Failed to get video URL');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error getting YouTube video: $e');
      return null;
    }
  }

  Future<void> _importYouTubeDirectly(String youtubeUrl) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _YouTubeDownloadDialog(
        youtubeUrl: youtubeUrl,
        onComplete: () {
          if (mounted) {
            _fetchProjects();
            _showSnackBar('✅ YouTube video downloaded and imported!');
          }
        },
        onError: (msg) {
          if (mounted) _showSnackBar('❌ $msg', isError: true);
        },
      ),
    );
  }

  void _showYouTubeImportDialog() {
    final controller = TextEditingController();

    bool submitted = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Download YouTube Video'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter the YouTube video URL:'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'https://youtube.com/watch?v=...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: submitted ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: submitted
                  ? null
                  : () {
                      final url = controller.text.trim();
                      if (url.isEmpty) return;
                      setState(() => submitted = true);
                      Navigator.pop(ctx);
                      _importYouTubeDirectly(url);
                    },
              child: const Text('Download & Import'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Import from text ─────────────────────────────────────────
  Future<void> _importVideosFromText() async {
    if (!mounted) return;

    final controller = TextEditingController();
    bool autoSegmentation = true;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Import Videos from Text'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste video URLs (one per line):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                width: 400,
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    hintText:
                        'https://example.com/video1.mp4\nhttps://youtube.com/watch?v=abc123\nhttps://example.com/video2.mp4\n...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: autoSegmentation,
                    onChanged: (v) => setState(() => autoSegmentation = v!),
                  ),
                  const Text('Auto Segmentation for all videos'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Supports: direct video URLs (MP4, WebM, MOV) and YouTube links',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 4),
              Text(
                'Note: YouTube links may not work reliably. Consider using a dedicated YouTube downloader service.',
                style: TextStyle(fontSize: 11, color: Colors.orange[700]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Import Videos'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;

    final text = controller.text.trim();
    final urls = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (urls.isEmpty) {
      _showSnackBar('No URLs found in text.', isError: true);
      return;
    }

    await _importVideosFromUrls(urls, autoSegmentation);
  }

  bool _isValidUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.scheme == 'http' || uri.scheme == 'https';
    } catch (_) {
      return false;
    }
  }

  Future<void> _importVideosFromUrls(
      List<String> urls, bool autoSegmentation) async {
    if (!mounted) return;

    List<Map<String, String>> resolvedUrls = [];
    List<String> errors = [];

    for (final url in urls) {
      if (_isYouTubeUrl(url)) {
        final videoUrl = await _getYouTubeVideoUrl(url);
        if (videoUrl != null) {
          resolvedUrls.add({'original': url, 'resolved': videoUrl});
          debugPrint('✅ Resolved YouTube URL: $url -> $videoUrl');
        } else {
          errors.add('Could not resolve YouTube URL: $url');
          debugPrint('❌ Failed to resolve YouTube URL: $url');
        }
      } else if (_isValidUrl(url)) {
        resolvedUrls.add({'original': url, 'resolved': url});
      } else {
        errors.add('Invalid URL: $url');
      }
    }

    if (errors.isNotEmpty) {
      final errorMessage = errors.join('\n');
      _showSnackBar('⚠️ Errors:\n$errorMessage', isError: true);
    }

    if (resolvedUrls.isEmpty) {
      _showSnackBar('No valid video URLs found to import.', isError: true);
      return;
    }

    final finalUrls = resolvedUrls.map((e) => e['resolved']!).toList();

    showDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ImportVideosDialog(
        urls: finalUrls,
        autoSegmentation: autoSegmentation,
        importSource: resolvedUrls.isNotEmpty
            ? resolvedUrls.first['original']
            : null,
        onComplete: () {
          if (mounted) {
            Navigator.pop(ctx);
            _fetchProjects();
            final errorCount = errors.length;
            final message = errorCount > 0
                ? '✅ Import completed! ($errorCount failed)'
                : '✅ Import completed!';
            _showSnackBar(message);
          }
        },
        onError: (error) {
          if (mounted) {
            _showSnackBar('❌ Import error: $error', isError: true);
          }
        },
      ),
    );
  }

  // ─── Navigation and actions ───────────────────────────────────
  Future<void> _openSessionDetail(String videoKey) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveTranscriptScreen(videoKey: videoKey),
      ),
    );
    if (!mounted) return;
    await _updateWorkingScreenUrl();
  }

  Future<void> _openEnhancement(String videoKey) async {
    Navigator.pushNamed(context, '/enhancement', arguments: videoKey);
    await _updateWorkingScreenUrl();
  }

  void _showContextMenu(BuildContext context, VideoProject project) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Open Session Detail'),
              onTap: () {
                Navigator.pop(ctx);
                _openSessionDetail(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Open Enhancement'),
              onTap: () {
                Navigator.pop(ctx);
                _openEnhancement(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('Video Information'),
              onTap: () {
                Navigator.pop(ctx);
                _showVideoInfo(project);
              },
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('Show Generated Segments'),
              onTap: () {
                Navigator.pop(ctx);
                _showGeneratedSegments(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: const Text('Show Progress'),
              onTap: () {
                Navigator.pop(ctx);
                _showProgress(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: const Text('Video Segmentation'),
              onTap: () {
                Navigator.pop(ctx);
                _showSegmentationSettings(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('Show Segments'),
              onTap: () {
                Navigator.pop(ctx);
                _showSegmentsList(project.key);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: Text(project.folder == null
                  ? 'Move to folder'
                  : 'Move to folder (now: ${project.folder})'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFolderFor(project);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename Project'),
              onTap: () {
                Navigator.pop(ctx);
                _editProjectName(project);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Edit Source'),
              onTap: () {
                Navigator.pop(ctx);
                _editProjectSource(project);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Delete Project',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteProject(project.key);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showVideoInfo(VideoProject project) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Video Information'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Name: ${project.name}'),
              Text('File: ${project.fileName}'),
              Text('Source: ${project.source}'),
              Text(
                'Codec: '
                '${project.codec.isEmpty ? "unknown" : project.codec}',
              ),
              Text('Duration: ${project.duration.toStringAsFixed(2)} s'),
              Text('FPS: ${project.fps.toStringAsFixed(1)}'),
              Text('File Size: ${_formatBytes(project.fileSize)}'),
              Text('Uploaded: ${_formatExactTimestamp(project.uploaded)}'),
              if (project.lastOpened != null)
                Text(
                  'Last Opened: '
                  '${_formatExactTimestamp(project.lastOpened!)}',
                ),
              Text('Segments: ${project.segmentCount}'),
              Text('Green-screen: ${project.greenscreenStatus}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showGeneratedSegments(String videoKey) {
    Navigator.pushNamed(context, '/generated_segments', arguments: videoKey);
  }

  void _showProgress(String videoKey) {
    Navigator.pushNamed(context, '/progress', arguments: videoKey);
  }

  void _showSegmentationSettings(String videoKey) {
    Navigator.pushNamed(context, '/segmentation', arguments: videoKey);
  }

  void _showSegmentsList(String videoKey) {
    Navigator.pushNamed(context, '/segments_list', arguments: videoKey);
  }

  // ─── Delete ───────────────────────────────────────────────────
  Future<void> _deleteProject(String videoKey) async {
    if (!mounted) return;

    final confirm = await _confirmAction(
        'Delete this project permanently? This cannot be undone.');
    if (!confirm) return;

    try {
      final response = await http.post(
        Uri.parse('$authBaseUrl/delete-video/$videoKey'),
        headers: {'Content-Type': 'application/json'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showSnackBar('Project deleted.');
        _greenscreenTriggered.remove(videoKey);
        _fetchProjects();
      } else {
        _showSnackBar(
          'Failed to delete (HTTP ${response.statusCode}).',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<bool> _confirmAction(String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirm'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ─── Edit name ────────────────────────────────────────────────
  Future<void> _editProjectName(VideoProject project) async {
    if (!mounted) return;

    final controller = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Project Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('$authBaseUrl/update-project-name/${project.key}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'project_name': newName}),
        );
        if (!mounted) return;
        if (response.statusCode == 200) {
          _showSnackBar('Project name updated.');
          _fetchProjects();
        } else {
          _showSnackBar('Failed to update name.', isError: true);
        }
      } catch (e) {
        if (mounted) _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  // ─── Edit source ─────────────────────────────────────────────
  Future<void> _editProjectSource(VideoProject project) async {
    if (!mounted) return;

    final controller = TextEditingController(text: project.source);
    String? errorText;

    final newSource = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Source'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Where did this video come from?',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: 'Source',
                  hintText:
                      'https://youtube.com/watch?v=…  or  Desktop Upload',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.upload_file, size: 16),
                    label: const Text('Desktop Upload'),
                    onPressed: () => setDialogState(() {
                      controller.text = 'Desktop Upload';
                      errorText = null;
                    }),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.clear, size: 16),
                    label: const Text('Clear'),
                    onPressed: () => setDialogState(() {
                      controller.text = '';
                    }),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) {
                  setDialogState(
                      () => errorText = 'Source cannot be empty.');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (newSource == null || newSource.isEmpty) return;
    if (newSource == project.source) return;

    try {
      final response = await http.post(
        Uri.parse('$authBaseUrl/update-project-source/${project.key}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'source': newSource}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        // Optimistic local update so the UI feels instant. The next
        // refresh will re-sync with the server's canonical value.
        setState(() {
          final i = _projects.indexWhere((p) => p.key == project.key);
          if (i >= 0) {
            _projects[i] = _copyProjectWithSource(_projects[i], newSource);
          }
        });
        _showSnackBar('Source updated.');
      } else {
        _showSnackBar(
          'Failed to update source (HTTP ${response.statusCode}).',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) _showSnackBar('Error: $e', isError: true);
    }
  }

  /// Returns a copy of `p` with a new `source`. Keeps `VideoProject`
  /// immutable and avoids a large copyWith.
  VideoProject _copyProjectWithSource(VideoProject p, String source) {
    return VideoProject(
      key: p.key,
      name: p.name,
      fileName: p.fileName,
      uploaded: p.uploaded,
      lastOpened: p.lastOpened,
      duration: p.duration,
      fps: p.fps,
      codec: p.codec,
      fileSize: p.fileSize,
      segmentCount: p.segmentCount,
      languages: p.languages,
      thumbnailUrl: p.thumbnailUrl,
      segmentationDone: p.segmentationDone,
      segmentationProgress: p.segmentationProgress,
      greenscreenFileName: p.greenscreenFileName,
      greenscreenStatus: p.greenscreenStatus,
      greenscreenProgress: p.greenscreenProgress,
      source: source,
      folder: p.folder,
    );
  }

  /// Small colour-coded chip that flags the codec at a glance.
  Widget _buildCodecChip(String codec, Responsive r) {
    final lower = codec.toLowerCase();

    Color bg;
    Color fg;
    if (lower.startsWith('h264') || lower.startsWith('avc')) {
      // Green: universal browser support.
      bg = Colors.green.shade50;
      fg = Colors.green.shade800;
    } else if (lower.startsWith('hevc') || lower.startsWith('h265')) {
      // Orange: playable, but not everywhere.
      bg = Colors.orange.shade50;
      fg = Colors.orange.shade800;
    } else if (lower.startsWith('av1')) {
      bg = Colors.blue.shade50;
      fg = Colors.blue.shade800;
    } else if (lower.startsWith('vp9') || lower.startsWith('vp8')) {
      bg = Colors.purple.shade50;
      fg = Colors.purple.shade800;
    } else {
      bg = Colors.grey.shade200;
      fg = Colors.grey.shade800;
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: r.spaceXS,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(r.spaceXS),
      ),
      child: Text(
        codec,
        style: TextStyle(
          fontSize: r.fontCaption - 1,
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }  

  // ─── Upload ───────────────────────────────────────────────────
  Future<void> _uploadVideo() async {
    if (!mounted) return;
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );
    if (result == null || result.files.isEmpty) return;

    final pickedFile = result.files.single;
    final fileName = pickedFile.name;
    final bytes = pickedFile.bytes;

    if (bytes == null) {
      _showSnackBar('Failed to read file bytes', isError: true);
      return;
    }

    showDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _UploadDialog(
        bytes: bytes,
        fileName: fileName,
        mode: UploadMode.chunked,
        onUploadComplete: _fetchProjects,
      ),
    );
  }

  // ─── Logout ───────────────────────────────────────────────────
  Future<void> _logoutPublic() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await InternalAuthService.clearTokens();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  // ─── UI ───────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final r = Responsive.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(appTitle),
            FutureBuilder<String>(
              future: _currentUserEmail(),
              builder: (_, snap) {
                final email = snap.data ?? '';
                if (email.isEmpty) return const SizedBox.shrink();
                return Text(
                  email,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.normal,
                    color: Colors.white70,
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          const UiModeToggle(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _showLive
                ? () => setState(() => _liveReload++)
                : _fetchProjects,
            tooltip: 'Refresh list',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logoutPublic,
            tooltip: 'Logout from public server',
          ),
        ],
      ),
      body: _withDropZone(_showLive
          ? LiveSessionsScreen(
              embedded: true,
              top: _buildTabSwitcher(r),
              reloadToken: _liveReload,
            )
          : CustomScrollView(
              // Connection panel, header, storage bar and grid all live
              // in one scroll view. On a tall window everything fits and
              // no scrollbar appears; on a short window the top parts
              // scroll off instead of squeezing the grid into a negative
              // height.
              slivers: [
                // ─── Server + connection (top of every page) ──────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        _pagePad(context), _pagePad(context),
                        _pagePad(context), 0),
                    child: const ServerConnectionPanel(),
                  ),
                ),
                // ─── Videos / Live transcripts ────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        _pagePad(context), _pagePad(context),
                        _pagePad(context), 0),
                    child: _buildTabSwitcher(r),
                  ),
                ),
                if (_isLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                // ─── Header: search / sort / upload ───────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        _pagePad(context), _pagePad(context),
                        _pagePad(context), 8),
                    child: _buildHeaderRow(r),
                  ),
                ),

                // ─── Folders ──────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        _pagePad(context), 0, _pagePad(context), 12),
                    child: _buildFolderBar(r),
                  ),
                ),

                // ─── Storage bar (Expert only) ────────────────────
                if (UiMode.isExpert)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: r.spaceL),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                'Storage used (input videos)',
                                style: TextStyle(
                                  fontSize: r.fontBodySmall,
                                  color: Colors.grey[600],
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${_storageUsed.toStringAsFixed(2)} GB / '
                              '${_storageLimit.toStringAsFixed(0)} GB',
                              style: TextStyle(
                                fontSize: r.fontBodySmall,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: r.spaceXS),
                        LinearProgressIndicator(
                          value: _storageLimit > 0
                              ? _storageUsed / _storageLimit
                              : 0,
                          backgroundColor: Colors.grey[300],
                          valueColor: const AlwaysStoppedAnimation(
                              Colors.blue),
                          minHeight: 4,
                        ),
                      ],
                    ),
                  ),
                ),

                // ─── Grid ─────────────────────────────────────────
                SliverPadding(
                  padding: EdgeInsets.only(
                    left: r.spaceL,
                    right: r.spaceL,
                    top: r.spaceS,
                    bottom: r.spaceL,
                  ),
                  sliver: _buildGridSliver(),
                ),
                ],
              ],
            )),
    );
  }
  /// Search field, sort dropdown and upload button. Wraps to two lines
  /// on compact viewports so nothing gets crushed.
  Widget _buildHeaderRow(Responsive r) {
    // Same look as the search field of the Live transcripts list.
    final searchField = TextField(
      decoration: const InputDecoration(
        hintText: 'Search videos by name or file…',
        prefixIcon: Icon(Icons.search),
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (value) {
        setState(() => _searchQuery = value);
      },
    );

    final sortDropdown = DropdownButton<String>(
      value: _sortMode,
      style: TextStyle(fontSize: r.fontBody, color: Colors.black87),
      items: const [
        DropdownMenuItem(value: 'newest', child: Text('Newest First')),
        DropdownMenuItem(value: 'oldest', child: Text('Oldest First')),
        DropdownMenuItem(value: 'last-opened', child: Text('Last Opened')),
        DropdownMenuItem(value: 'az', child: Text('Name A → Z')),
        DropdownMenuItem(value: 'za', child: Text('Name Z → A')),
      ],
      onChanged: (value) {
        if (value != null) setState(() => _sortMode = value);
      },
    );

    // One "Video Upload" button; every import path is a sub-option.
    final uploadButton = MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.upload_file),
          onPressed: _uploadVideo,
          child: const Text('From this device'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.play_circle_outline),
          onPressed: _showYouTubeImportDialog,
          child: const Text('From YouTube URL'),
        ),
        if (UiMode.isExpert)
          MenuItemButton(
            leadingIcon: const Icon(Icons.text_snippet),
            onPressed: _importVideosFromText,
            child: const Text('From text links'),
          ),
      ],
      // Same size and style as "New live session" in the live list.
      builder: (context, controller, _) => FilledButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.upload),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Video Upload'),
            Icon(
              controller.isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              size: 22,
            ),
          ],
        ),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );

    // Same layout as the Live transcripts list: big button first, then
    // search (phones: stacked, full width).
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          uploadButton,
          const SizedBox(height: 12),
          searchField,
          if (UiMode.isExpert) ...[
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: sortDropdown),
          ],
        ],
      );
    }

    return Row(
      children: [
        uploadButton,
        const SizedBox(width: 16),
        Expanded(child: searchField),
        if (UiMode.isExpert) ...[
          const SizedBox(width: 12),
          sortDropdown,
        ],
      ],
    );
  }

  /// The grid, as a sliver so it can sit inside the CustomScrollView
  /// in build(). Error and empty states are wrapped in
  /// SliverToBoxAdapter so the whole thing stays a sliver.
  Widget _buildGridSliver() {
    final r = Responsive.of(context);

    // ── Error state ─────────────────────────────────────────────
    if (_listError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(r.spaceXL),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: r.width * 0.9),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(r.spaceM),
                side: BorderSide(color: Colors.orange.shade200),
              ),
              color: Colors.orange.shade50,
              child: Padding(
                padding: EdgeInsets.all(r.spaceL),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.cloud_off,
                            size: r.iconLarge,
                            color: Colors.orange.shade800),
                        SizedBox(width: r.spaceM),
                        Expanded(
                          child: Text(
                            'Cannot load projects',
                            style: TextStyle(
                              fontSize: r.fontSubtitle,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: r.spaceM),
                    SelectableText(
                      _listError!,
                      style: TextStyle(
                        fontSize: r.fontBody,
                        height: 1.45,
                        color: Colors.black87,
                      ),
                    ),
                    SizedBox(height: r.spaceL),
                    Wrap(
                      spacing: r.spaceM,
                      runSpacing: r.spaceS,
                      children: [
                        FilledButton.icon(
                          onPressed: _fetchProjects,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showBackendHelp,
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: const Text('How to fix'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // ── Filter + sort ────────────────────────────────────────────
    final filtered = _projects.where((p) {
      if (_folderFilter == _unsortedFilter && p.folder != null) return false;
      if (_folderFilter != null &&
          _folderFilter != _unsortedFilter &&
          p.folder != _folderFilter) {
        return false;
      }
      final q = _searchQuery.toLowerCase();
      return p.name.toLowerCase().contains(q) ||
          p.fileName.toLowerCase().contains(q);
    }).toList();

    filtered.sort((a, b) {
      switch (_sortMode) {
        case 'newest':
          return b.uploaded.compareTo(a.uploaded);
        case 'oldest':
          return a.uploaded.compareTo(b.uploaded);
        case 'last-opened':
          final aTime = a.lastOpened ?? a.uploaded;
          final bTime = b.lastOpened ?? b.uploaded;
          return bTime.compareTo(aTime);
        case 'az':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'za':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        default:
          return 0;
      }
    });

    // ── Empty state ─────────────────────────────────────────────
    if (filtered.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: r.spaceXL),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open,
                    size: r.iconExtraLarge, color: Colors.grey),
                SizedBox(height: r.spaceL),
                Text('No projects found',
                    style: TextStyle(fontSize: r.fontSubtitle)),
                Text(
                  'Upload a video or drag one onto this window to get started.',
                  style: TextStyle(fontSize: r.fontBody, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ── Card height ──────────────────────────────────────────────
    final columns = r.gridColumns();
    final cardWidth = (r.width - r.spaceL * 2) / columns;

    // Fixed thumbnail height for this column width (16:9).
    final thumbnailHeight = cardWidth * 9 / 16;

    // Fixed height of everything below the thumbnail:
    //   name, filename, source, meta row, pipeline status, paddings
    const metadataHeight = 110.0;

    // Fixed height of the bottom action row.
    final actionHeight = r.iconMedium + r.spaceS + r.spaceXS * 2;

    // mainAxisExtent gives every cell a fixed pixel height that no
    // longer swings with the viewport. The card is exactly as tall
    // as its content and no taller.
    final cellHeight = thumbnailHeight + metadataHeight + actionHeight;

    // ── The grid itself ──────────────────────────────────────────
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: cellHeight,
        crossAxisSpacing: r.spaceM,
        mainAxisSpacing: r.spaceM,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildCard(filtered[index]),
        childCount: filtered.length,
      ),
    );
  }

  /// Card that can be dragged onto a folder chip (mouse / wide screens;
  /// on phones dragging would fight with scrolling, so the folder button
  /// and long-press menu are used there).
  Widget _buildCard(VideoProject project) {
    final card = _buildCardBody(project);
    if (MediaQuery.sizeOf(context).width < 600) return card;
    return Draggable<String>(
      data: project.key,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(project.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }

  Widget _buildCardBody(VideoProject project) {
    final r = Responsive.of(context);

    return GestureDetector(
      onLongPress: () => _showContextMenu(context, project),
      onTap: () => _openSessionDetail(project.key),
      child: Card(
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(r.spaceS),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail: fixed 16:9 ──────────────────────────────
            AspectRatio(
              aspectRatio: 16 / 9,
              child: project.thumbnailUrl != null &&
                      project.thumbnailUrl!.isNotEmpty
                  ? Image.network(
                      project.thumbnailUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildThumbnailPlaceholder(project),
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: Colors.grey[300],
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: loadingProgress.expectedTotalBytes != null
                                  ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                  : null,
                            ),
                          ),
                        );
                      },
                    )
                  : _buildThumbnailPlaceholder(project),
            ),

            // ── Metadata ───────────────────────────────────────────
            // Expanded so this block claims all vertical space between
            // the thumbnail and the action row. Any extra height the
            // grid cell has (from mainAxisExtent) lands here rather
            // than as an empty strip below the action row.
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  r.spaceS, r.spaceXS, r.spaceS, 0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => _editProjectName(project),
                      child: Text(
                        project.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: r.fontBodySmall,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (UiMode.isExpert) ...[
                    Text(
                      project.fileName,
                      style: TextStyle(
                        fontSize: r.fontCaption,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),

                    // ── Editable source line ───────────────────────
                    const SizedBox(height: 2),
                    InkWell(
                      onTap: () => _editProjectSource(project),
                      borderRadius: BorderRadius.circular(r.spaceXS),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: r.spaceXS,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _isYouTubeUrl(project.source)
                                  ? Icons.smart_display_outlined
                                  : Icons.upload_file,
                              size: r.fontCaption + 2,
                              color: Colors.blueGrey,
                            ),
                            SizedBox(width: r.spaceXS / 2),
                            Expanded(
                              child: Text(
                                project.source,
                                style: TextStyle(
                                  fontSize: r.fontCaption,
                                  color: Colors.blue[700],
                                  decoration: TextDecoration.underline,
                                  decorationStyle:
                                      TextDecorationStyle.dotted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Icon(
                              Icons.edit,
                              size: r.fontCaption,
                              color: Colors.grey[400],
                            ),
                          ],
                        ),
                      ),
                    ),
                    ],

                    SizedBox(height: r.spaceXS / 2),

                    // ── Meta row: duration • segs • codec • date ──
                    // (segments + codec only in Expert mode)
                    Row(
                      children: [
                        Text(
                          _formatDuration(project.duration),
                          style: TextStyle(
                            fontSize: r.fontCaption,
                            color: Colors.grey[500],
                          ),
                        ),
                        if (UiMode.isExpert) ...[
                        SizedBox(width: r.spaceXS),
                        Text(
                          '• ${project.segmentCount} segs',
                          style: TextStyle(
                            fontSize: r.fontCaption,
                            color: Colors.grey[500],
                          ),
                        ),
                        ],
                        if (UiMode.isExpert && project.codec.isNotEmpty) ...[
                          SizedBox(width: r.spaceXS),
                          // Flexible so the chip can shrink (and the
                          // inner Text ellipsize) instead of forcing
                          // the whole Row to overflow.
                          Flexible(
                            child: _buildCodecChip(project.codec, r),
                          ),
                        ],
                        SizedBox(width: r.spaceXS),
                        // Expanded + right alignment replaces the old
                        // Spacer(). When the card is narrow the
                        // timestamp ellipsizes rather than pushing
                        // the Row past its constraint.
                        Expanded(
                          child: Tooltip(
                            message:
                                _formatExactTimestamp(project.uploaded),
                            child: Text(
                              _formatJobTimestamp(project.uploaded),
                              style: TextStyle(
                                fontSize: r.fontCaption,
                                color: Colors.grey[400],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: r.spaceXS / 2),
                    _buildPipelineStatus(project),
                  ],
                ),
              ),
            ),         
            // ── Action row ─────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(
                r.spaceXS, 0, r.spaceS, r.spaceXS,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _deleteProject(project.key),
                    icon: Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: r.iconSmall,
                    ),
                    tooltip: 'Delete',
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                      minWidth: r.spaceXL,
                      minHeight: r.spaceXL,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _pickFolderFor(project),
                    icon: Icon(
                      project.folder == null
                          ? Icons.drive_file_move_outlined
                          : Icons.folder,
                      color: Colors.amber.shade800,
                      size: r.iconSmall,
                    ),
                    tooltip: project.folder == null
                        ? 'Move to folder'
                        : 'Folder: ${project.folder} — move',
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                      minWidth: r.spaceXL,
                      minHeight: r.spaceXL,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: r.iconMedium + r.spaceS,
                    child: ElevatedButton(
                      onPressed: () => _openSessionDetail(project.key),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: r.spaceM,
                        ),
                        textStyle: TextStyle(fontSize: r.fontCaption),
                        minimumSize: Size(0, r.iconMedium + r.spaceS),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailPlaceholder(VideoProject project) {
    final r = Responsive.of(context);

    return Container(
      color: Colors.grey[800],
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.grey[800]!, Colors.grey[900]!],
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: r.iconLarge + r.spaceS,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                SizedBox(height: r.spaceXS),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: r.spaceS,
                    vertical: r.spaceXS / 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(r.spaceXS),
                  ),
                  child: Text(
                    _formatDuration(project.duration),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: r.fontCaption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: r.spaceS,
            right: r.spaceS,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: r.spaceXS,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(r.spaceXS / 2),
              ),
              child: Text(
                project.fileName.split('.').last.toUpperCase(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: r.fontCaption - 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineStatus(VideoProject project) {
    final r = Responsive.of(context);
    final iconSize = r.fontSmall;
    final labelStyle = TextStyle(
      fontSize: r.fontCaption,
      color: Colors.green,
    );

    final gs = project.greenscreenStatus;

    if (gs == 'ready') {
      return Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: iconSize),
          SizedBox(width: r.spaceXS / 2),
          Text('Green-screen ready', style: labelStyle),
        ],
      );
    }

    if (gs == 'building') {
      final pct = project.greenscreenProgress;
      return Row(
        children: [
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: pct > 0 ? pct / 100.0 : null,
            ),
          ),
          SizedBox(width: r.spaceXS / 2),
          Text(
            pct > 0 ? 'Preparing $pct%' : 'Preparing…',
            style: TextStyle(fontSize: r.fontCaption, color: Colors.blue),
          ),
        ],
      );
    }

    if (gs == 'failed') {
      return Row(
        children: [
          Icon(Icons.error_outline,
              color: Colors.orange, size: iconSize),
          SizedBox(width: r.spaceXS / 2),
          Text(
            'Prep failed',
            style: TextStyle(fontSize: r.fontCaption, color: Colors.orange),
          ),
        ],
      );
    }

    if (project.segmentationDone) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: iconSize),
          SizedBox(width: r.spaceXS / 2),
          Text('Done', style: labelStyle),
        ],
      );
    }

    return Row(
      children: [
        Icon(Icons.hourglass_empty, color: Colors.grey, size: iconSize),
        SizedBox(width: r.spaceXS / 2),
        Text(
          'Not prepared',
          style: TextStyle(fontSize: r.fontCaption, color: Colors.grey),
        ),
      ],
    );
  }

  /// Formats a job-history timestamp:
  ///
  ///   < 7 days     → "25/08/2026 08:14"   (date + time)
  ///   < 30 days    → "25/08/2026"          (date only)
  ///   ≥ 30 days    → "2026"                (year only)
  ///
  /// `dt` is expected in local time. Convert UTC first if needed.
  String _formatJobTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();

    if (diff.inDays < 7) {
      // Recent: full timestamp with seconds
      return '$dd/$mo/$yyyy $hh:$mm:$ss';
    }
    if (diff.inDays < 30) {
      // This month: date + time, seconds hidden
      return '$dd/$mo/$yyyy $hh:$mm';
    }
    // Older: still show the time, just drop the year's leading digits
    // if you like — but keep HH:MM, it's cheap and useful.
    return '$dd/$mo/$yyyy $hh:$mm';
  }

  /// Always shows the full date + time. Used where precision matters
  /// (info dialogs, tooltips), as opposed to the compact card label.
  String _formatExactTimestamp(DateTime dt) {
    if (dt.millisecondsSinceEpoch == 0) return 'unknown';
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$dd/$mo/$yyyy $hh:$mm:$ss';
  }

  String _formatDuration(double seconds) {
    final duration = Duration(seconds: seconds.round());
    final minutes = duration.inMinutes;
    final remainingSeconds = duration.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

// ─── Import Videos Dialog ──────────────────────────────────────
class _ImportVideosDialog extends StatefulWidget {
  final List<String> urls;
  final bool autoSegmentation;
  final VoidCallback onComplete;
  final Function(String) onError;

  /// Optional: the source URL to record on the project (e.g. the
  /// original YouTube URL when the downloader resolved it to a
  /// direct-link URL). Passed straight through to `finish-upload`.
  final String? importSource;

  const _ImportVideosDialog({
    required this.urls,
    required this.autoSegmentation,
    required this.onComplete,
    required this.onError,
    this.importSource,
  });

  @override
  State<_ImportVideosDialog> createState() => _ImportVideosDialogState();
}

class _ImportVideosDialogState extends State<_ImportVideosDialog> {
  List<ImportVideoStatus> _statuses = [];
  bool _isComplete = false;

  /// Shorthand for `widget.importSource`. The finish-upload payload
  /// records this so the backend can store it as the project's
  /// `source` field.
  String? get _importSource => widget.importSource;

  @override
  void initState() {
    super.initState();
    _statuses = widget.urls.map((url) => ImportVideoStatus(url: url)).toList();
    _startImport();
  }

  Future<void> _startImport() async {
    for (int i = 0; i < _statuses.length; i++) {
      if (!mounted) break;

      final status = _statuses[i];
      setState(() {
        status.state = ImportState.downloading;
        status.message = 'Downloading...';
      });

      try {
        final response = await http.get(
          Uri.parse(status.url),
          headers: {
            'Accept': 'video/*, application/octet-stream',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept-Encoding': 'identity',
          },
        );

        if (response.statusCode != 200) {
          throw Exception('Failed to download: HTTP ${response.statusCode}');
        }
        if (response.bodyBytes.isEmpty) {
          throw Exception('Downloaded file is empty');
        }

        final fileName = _extractFileNameFromUrl(status.url, response);

        setState(() => status.message = 'Uploading...');

        await _uploadVideoToServer(
          bytes: response.bodyBytes,
          fileName: fileName,
          autoSegmentation: widget.autoSegmentation,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                status.progress = progress;
                status.message = 'Uploading ${progress.toStringAsFixed(0)}%';
              });
            }
          },
        );

        setState(() {
          status.state = ImportState.completed;
          status.message = '✓ Complete';
          status.progress = 100;
        });
      } catch (e) {
        setState(() {
          status.state = ImportState.error;
          status.message = '✗ Error: $e';
        });
        if (mounted) {
          widget.onError('Failed to import ${status.url}: $e');
        }
      }
    }

    setState(() => _isComplete = true);
    widget.onComplete();
  }

  Future<void> _uploadVideoToServer({
    required Uint8List bytes,
    required String fileName,
    required bool autoSegmentation,
    required Function(double) onProgress,
  }) async {
    const chunkSize = 5 * 1024 * 1024;
    final totalBytes = bytes.length;
    final totalChunks = (totalBytes / chunkSize).ceil();

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end =
          (i + 1) * chunkSize > totalBytes ? totalBytes : (i + 1) * chunkSize;
      final chunk = bytes.sublist(start, end);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$authBaseUrl/upload-chunk'),
      );
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          chunk,
          filename: fileName,
          contentType: MediaType('video', 'mp4'),
        ),
      );
      request.fields['filename'] = fileName;
      request.fields['chunk_index'] = i.toString();
      request.fields['total_chunks'] = totalChunks.toString();

      final response = await request.send();
      if (response.statusCode != 200) {
        throw Exception('Chunk upload failed: ${response.statusCode}');
      }

      onProgress(((i + 1) / totalChunks) * 100);
    }

    final finishResponse = await http.post(
      Uri.parse('$authBaseUrl/finish-upload'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'filename': fileName,
        'auto_segmentation': autoSegmentation,
        // The URL-import dialog passes the URL it was asked to
        // download from, not the resolved direct-link URL.
        'source': _importSource ?? 'Imported',
      }),
    );
    if (finishResponse.statusCode != 200) {
      throw Exception('Finish upload failed');
    }
  }

  String _extractFileNameFromUrl(String url, http.Response response) {
    final disposition = response.headers['content-disposition'];
    if (disposition != null) {
      final match = RegExp(r'filename="([^"]+)"').firstMatch(disposition);
      if (match != null) return match.group(1)!;
    }
    try {
      final lastSegment = Uri.parse(url).path.split('/').last;
      if (lastSegment.contains('.')) return lastSegment;
    } catch (_) {}
    return 'video_${DateTime.now().millisecondsSinceEpoch}'
        '.${_getFileExtensionFromUrl(url)}';
  }

  String _getFileExtensionFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mp4')) return 'mp4';
    if (lower.contains('.webm')) return 'webm';
    if (lower.contains('.mov')) return 'mov';
    if (lower.contains('.avi')) return 'avi';
    if (lower.contains('.mkv')) return 'mkv';
    if (lower.contains('.flv')) return 'flv';
    if (lower.contains('.wmv')) return 'wmv';
    if (lower.contains('.m4v')) return 'm4v';
    return 'mp4';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isComplete ? 'Import Complete' : 'Importing Videos'),
      content: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isComplete)
              LinearProgressIndicator(
                value: _statuses.isEmpty
                    ? 0
                    : _statuses
                            .where((s) => s.state == ImportState.completed)
                            .length /
                        _statuses.length,
              ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _statuses.length,
                itemBuilder: (ctx, index) {
                  final status = _statuses[index];
                  return ListTile(
                    dense: true,
                    leading: _buildStatusIcon(status.state),
                    title: Text(
                      _truncateUrl(status.url, 60),
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Text(
                      status.message,
                      style: TextStyle(
                        fontSize: 12,
                        color: status.state == ImportState.error
                            ? Colors.red
                            : status.state == ImportState.completed
                                ? Colors.green
                                : Colors.grey,
                      ),
                    ),
                    subtitle: status.state == ImportState.downloading &&
                            status.progress > 0
                        ? LinearProgressIndicator(
                            value: status.progress / 100, minHeight: 4)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_isComplete)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildStatusIcon(ImportState state) {
    switch (state) {
      case ImportState.pending:
        return const Icon(Icons.pending, color: Colors.grey, size: 20);
      case ImportState.downloading:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ImportState.completed:
        return const Icon(Icons.check_circle, color: Colors.green, size: 20);
      case ImportState.error:
        return const Icon(Icons.error, color: Colors.red, size: 20);
    }
  }

  String _truncateUrl(String url, int maxLength) {
    if (url.length <= maxLength) return url;
    return '${url.substring(0, maxLength - 3)}...';
  }
}

// ─── Upload Dialog ─────────────────────────────────────────────
class _UploadDialog extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final VoidCallback onUploadComplete;
  final UploadMode mode;

  const _UploadDialog({
    required this.bytes,
    required this.fileName,
    required this.onUploadComplete,
    this.mode = UploadMode.chunked,
  });

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

enum UploadMode { chunked, forward, direct }

class _UploadDialogState extends State<_UploadDialog> {
  double _progress = 0.0;
  bool _isUploading = false;
  String _statusText = 'Ready';
  bool _autoSegmentation = true;

  String? _sessionId;
  bool _sessionComplete = false;
  String? _videoKey;

  @override
  void initState() {
    super.initState();
    _startUpload();
  }

  Future<void> _startUpload() async {
    setState(() {
      _isUploading = true;
      _statusText = 'Uploading…';
    });

    const chunkSize = 5 * 1024 * 1024;
    final totalBytes = widget.bytes.length;
    final totalChunks = (totalBytes / chunkSize).ceil();

    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize > totalBytes
            ? totalBytes
            : (i + 1) * chunkSize;
        final chunk = widget.bytes.sublist(start, end);

        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$authBaseUrl/upload-chunk'),
        );
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            chunk,
            filename: widget.fileName,
            contentType: MediaType('video', 'mp4'),
          ),
        );
        request.fields['filename'] = widget.fileName;
        request.fields['chunk_index'] = i.toString();
        request.fields['total_chunks'] = totalChunks.toString();

        final response = await request.send();
        if (response.statusCode != 200) {
          throw Exception('Chunk upload failed: ${response.statusCode}');
        }

        if (!mounted) return;
        setState(() {
          _progress = ((i + 1) / totalChunks) * 100;
          _statusText = 'Uploading ${_progress.toStringAsFixed(0)}%';
        });
      }

      final finishResponse = await http.post(
        Uri.parse('$authBaseUrl/finish-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': widget.fileName,
          'auto_segmentation': _autoSegmentation,
          'source': 'Desktop Upload',
        }),
      );
      if (finishResponse.statusCode != 200) {
        throw Exception('Finish upload failed');
      }

      final finishData =
          jsonDecode(finishResponse.body) as Map<String, dynamic>;
      _videoKey = (finishData['project'] as Map?)?['key'] as String?;

      if (!mounted) return;
      setState(() {
        _statusText = 'Upload complete';
        _isUploading = false;
      });

      widget.onUploadComplete();

      switch (widget.mode) {
        case UploadMode.chunked:
          _closeSoon();
          break;
        case UploadMode.forward:
          await _forwardToInternal();
          break;
        case UploadMode.direct:
          _closeSoon();
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error: $e';
        _isUploading = false;
      });
    }
  }

  Future<void> _forwardToInternal() async {
    if (_videoKey == null) {
      _closeSoon();
      return;
    }

    setState(() {
      _statusText = 'Submitting to the server…';
      _isUploading = true;
      _progress = 0;
    });

    try {
      final token = await InternalAuthService.getToken();
      final resp = await http.post(
        Uri.parse('$authBaseUrl/upload'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'video_key': _videoKey,
          'token': token,
          'name': widget.fileName.replaceAll('.mp4', ''),
        }),
      );

      if (resp.statusCode != 200) {
        throw Exception('Upload failed: ${resp.statusCode}');
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final sessionId = data['session_id'] as String?;
      if (sessionId == null) {
        throw Exception('Server did not return a session id');
      }

      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _isUploading = false;
        _statusText = 'Processing on the server…';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Forward error: $e';
        _isUploading = false;
      });
    }
  }

  void _closeSoon() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) Navigator.pop(context, true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionId != null) return _buildProcessingDialog(_sessionId!);
    return _buildUploadDialog();
  }

  Widget _buildUploadDialog() {
    return AlertDialog(
      title: const Text('Uploading Video'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress / 100),
          const SizedBox(height: 12),
          Text(_statusText),
          const SizedBox(height: 12),
          if (!_isUploading && _progress < 100)
            Row(
              children: [
                Checkbox(
                  value: _autoSegmentation,
                  onChanged: (v) =>
                      setState(() => _autoSegmentation = v ?? false),
                ),
                const Text('Auto Segmentation'),
              ],
            ),
        ],
      ),
      actions: [
        if (!_isUploading)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildProcessingDialog(String sessionId) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: Row(
        children: [
          Icon(
            _sessionComplete ? Icons.check_circle : Icons.hourglass_top,
            color: _sessionComplete ? Colors.green : Colors.blue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sessionComplete
                  ? 'Processing complete'
                  : 'Processing on the server',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: JobProgressPanel(
            sessionId: sessionId,
            onComplete: () {
              if (!mounted) return;
              setState(() => _sessionComplete = true);
              widget.onUploadComplete();
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(_sessionComplete ? 'Done' : 'Close'),
        ),
      ],
    );
  }
}

// ─── YouTube Download Dialog ───────────────────────────────────
class _YouTubeDownloadDialog extends StatefulWidget {
  final String youtubeUrl;
  final VoidCallback onComplete;
  final ValueChanged<String> onError;

  const _YouTubeDownloadDialog({
    required this.youtubeUrl,
    required this.onComplete,
    required this.onError,
  });

  @override
  State<_YouTubeDownloadDialog> createState() =>
      _YouTubeDownloadDialogState();
}

class _YouTubeDownloadDialogState extends State<_YouTubeDownloadDialog> {
  late final String _downloadId;
  Timer? _pollTimer;
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _events = const [];
  Map<String, dynamic> _details = const {};

  String _stage = 'starting';
  double _progressValue = 0.0;
  String _message = 'Starting…';

  bool _finished = false;
  String? _error;

  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    _downloadId = DateTime.now().microsecondsSinceEpoch.toString();
    _startDownload();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _poll(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    try {
      final response = await http.post(
        Uri.parse('$flaskServerUrl/api/youtube-download-and-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': widget.youtubeUrl,
          'auto_segmentation': true,
          'download_id': _downloadId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          setState(() {
            _finished = true;
            _progressValue = 1.0;
            _stage = 'done';
            _stopPolling();
          });
          widget.onComplete();
        } else {
          final msg = data['error']?.toString() ?? 'Unknown error';
          setState(() {
            _finished = true;
            _error = msg;
            _stopPolling();
          });
          widget.onError(msg);
        }
      } else {
        final msg = 'Server error: ${response.statusCode}';
        setState(() {
          _finished = true;
          _error = msg;
          _stopPolling();
        });
        widget.onError(msg);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finished = true;
        _error = 'Network error: $e';
        _stopPolling();
      });
      widget.onError('Network error: $e');
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    // Skip if the widget is gone, a previous poll is still running, or
    // the download has already finished (no point asking again).
    if (!mounted || _pollInFlight || _finished) return;

    _pollInFlight = true;
    try {
      final resp = await http.get(
        Uri.parse('$flaskServerUrl/api/download-progress/$_downloadId'),
      );
      if (resp.statusCode != 200 || !mounted) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final newEvents =
          (data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      setState(() {
        _events = newEvents;
        _details = (data['details'] as Map?)?.cast<String, dynamic>() ?? {};
        _stage = data['stage']?.toString() ?? _stage;
        _progressValue =
            (data['progress'] as num?)?.toDouble() ?? _progressValue;
        _message = data['message']?.toString() ?? _message;
      });

      // Once the server says we're done, stop the timer. The dialog
      // stays open until the user closes it; we just stop polling.
      if (data['done'] == true) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController
              .jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } catch (_) {
      // ignore transient polling errors
    } finally {
      _pollInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = MediaQuery.of(context).size.width * 0.8;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _error != null
                ? Icons.error_outline
                : _finished
                    ? Icons.check_circle
                    : Icons.downloading,
            color: _error != null
                ? Colors.red
                : _finished
                    ? Colors.green
                    : Colors.blue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error != null
                  ? 'Import Failed'
                  : _finished
                      ? 'Import Complete'
                      : 'Downloading YouTube Video',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth.clamp(400, 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.youtubeUrl,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progressValue.clamp(0.0, 1.0),
              minHeight: 6,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _stage.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  '${(_progressValue * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_details.isNotEmpty) _buildInfoCard(),
            const SizedBox(height: 12),
            const Text(
              'Log',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Container(
              height: 220,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade700),
              ),
              padding: const EdgeInsets.all(8),
              child: _events.isEmpty
                  ? const Center(
                      child: Text(
                        'Waiting for server…',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _events.length,
                      itemBuilder: (ctx, i) {
                        final ev = _events[i];
                        final level = ev['level']?.toString() ?? 'info';
                        final time = ev['time']?.toString() ?? '';
                        final msg = ev['message']?.toString() ?? '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: Colors.white,
                                height: 1.35,
                              ),
                              children: [
                                TextSpan(
                                  text: '$time  ',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                TextSpan(
                                  text: _icon(level),
                                  style: TextStyle(color: _colorFor(level)),
                                ),
                                const TextSpan(text: ' '),
                                TextSpan(
                                  text: msg,
                                  style: TextStyle(color: _colorFor(level)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_finished || _error != null)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildInfoCard() {
    final rows = <Widget>[];

    void addRow(String label, String? value, {Color? color}) {
      if (value == null || value.isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ));
    }

    addRow('Title', _details['title']?.toString());
    addRow('Filename', _details['filename']?.toString());
    addRow('Duration',
        _details['duration'] != null ? '${_details['duration']} s' : null);
    addRow(
      'File size',
      _details['filesize'] != null
          ? _formatBytes((_details['filesize'] as num).toInt())
          : null,
    );
    addRow(
      'Audio',
      _details['has_audio'] == null
          ? null
          : (_details['has_audio'] == true ? '✅ present' : '❌ missing'),
      color: _details['has_audio'] == true ? Colors.green : Colors.red,
    );
    addRow('Codec', _details['codec']?.toString());
    if (_details['converted'] == true) {
      addRow('Converted', 'H.264 (browser compatible)',
          color: Colors.green);
    } else if (_details['converted'] == false) {
      addRow('Converted', 'Not needed', color: Colors.grey);
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  String _icon(String level) {
    switch (level) {
      case 'error':
        return '✗';
      case 'warning':
        return '⚠';
      default:
        return '›';
    }
  }

  Color _colorFor(String level) {
    switch (level) {
      case 'error':
        return const Color(0xFFFF6B6B);
      case 'warning':
        return const Color(0xFFFFC107);
      default:
        return const Color(0xFFB0BEC5);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}