// live_sessions_screen.dart
//
// Entry screen for live speech recognition, opened from the mic button
// on the working screen:
//
//   Working screen ──► Live Sessions (this) ──► New live session
//                                         └──► finished session (read-only)
//
// Lists the user's finished live sessions saved on the backend
// (/api/live/saved), newest first. Sessions can be sorted into the same
// folders as the videos on the working screen (/api/folders).

import 'dart:convert';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/screens/live_asr_screen.dart';
import 'package:asr_live_translator/screens/live_session_view_screen.dart';
import 'package:asr_live_translator/screens/session_output_screen.dart';
import 'package:asr_live_translator/services/live_sessions_api.dart';
import 'package:asr_live_translator/services/app_url.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:asr_live_translator/services/ui_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:asr_live_translator/widgets/server_connection_panel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LiveSessionsScreen extends StatefulWidget {
  const LiveSessionsScreen({
    super.key,
    this.embedded = false,
    this.top,
    this.reloadToken = 0,
    this.openId,
  });

  /// Open this session after the first load (deep link
  /// /live-sessions/<email>/<id>); "new" starts a new recording.
  final String? openId;

  /// Shown inside another page (the working screen's "Live sessions"
  /// tab): no Scaffold / AppBar of its own.
  final bool embedded;

  /// Extra widget under the server panel (e.g. the Videos / Live switcher).
  final Widget? top;

  /// Change it to make the list reload (the host page's Refresh button).
  final int reloadToken;

  @override
  State<LiveSessionsScreen> createState() => _LiveSessionsScreenState();
}

class _LiveSessionsScreenState extends State<LiveSessionsScreen>
    with UiModeListener<LiveSessionsScreen> {
  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;
  double _pad(BuildContext c) => _isNarrow(c) ? 12 : 24;

  List<LiveSessionSummary> _sessions = const [];
  bool _loading = true;
  String? _error;
  bool _needsConnect = false;
  String _search = '';

  // ─── Folders (shared with the video list) ───
  static const String _unsortedFilter = '\u0000unsorted';
  static const String _folderFilterPref = 'live_folder_filter';
  List<String> _folders = [];
  String? _folderFilter; // null = all, _unsortedFilter, or a folder name
  String? _dropHover;

  @override
  void initState() {
    super.initState();
    // Sessions belong to the login: reload when it or the server changes.
    ServerConnection.tokenChanged.addListener(_load);
    ServerConnection.serverChanged.addListener(_load);
    _init();
  }

  @override
  void didUpdateWidget(LiveSessionsScreen old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken && !_loading) _load();
  }

  @override
  void dispose() {
    ServerConnection.tokenChanged.removeListener(_load);
    ServerConnection.serverChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _init() async {
    await ServerConfigService.load();
    if (!LanguageConfig.isLoaded) {
      try {
        await LanguageConfig.load();
      } catch (_) {}
    }
    await _load();
  }

  Future<void> _load() async {
    _fetchFolders();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await LiveSessionsApi.list();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _needsConnect = false;
        _loading = false;
      });
      _handleOpenId();
    } on LiveSessionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _needsConnect = e.isAuth;
        _error = e.isAuth ? null : e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load live sessions: $e';
        _loading = false;
      });
    }
  }

  // ─── navigation ──────────────────────────────────────────────────
  Future<void> _newSession() async {
    await AppUrl.set(AppUrl.live, 'new');
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LiveAsrScreen()),
    );
    await AppUrl.set(AppUrl.live);
    if (mounted) _load();
  }

  /// Deep link: open the session named in the address once the list is in.
  bool _openIdHandled = false;
  void _handleOpenId() {
    final id = widget.openId;
    if (_openIdHandled || id == null || id.isEmpty) return;
    _openIdHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (id == 'new') {
        _newSession();
        return;
      }
      final s = _sessions
          .where((x) => x.outputSessionId == id || x.id == id)
          .firstOrNull;
      if (s != null) {
        _open(s);
      } else {
        AppUrl.set(AppUrl.live);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That live session was not found.')),
        );
      }
    });
  }

  Future<void> _open(LiveSessionSummary s) async {
    // Sessions recorded with the current relay have full output files:
    // open them in the same Session Output screen as uploaded videos.
    // The address shows this live session while it is open.
    await AppUrl.set(
        AppUrl.live, s.outputSessionId.isNotEmpty ? s.outputSessionId : s.id);
    if (!mounted) return;
    if (s.outputSessionId.isNotEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SessionOutputScreen(
            sessionId: s.outputSessionId,
            sessionUrl: '',
          ),
        ),
      );
      await AppUrl.set(AppUrl.live);
      return;
    }
    // Older live sessions only have the saved text.
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => LiveSessionViewScreen(sessionId: s.id)),
    );
    await AppUrl.set(AppUrl.live);
    if (deleted == true && mounted) _load();
  }

  /// Give the session a chosen name (shown above live_<date>-<time>).
  Future<void> _rename(LiveSessionSummary s) async {
    final controller = TextEditingController(text: s.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Session name',
                hintText: 'e.g. Lecture International Law, week 3',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            Text(
              'Recorded as: ${s.name}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
        actions: [
          if (s.title.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Remove name'),
            ),
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
    // Controller left to the GC (disposing races the closing animation).
    if (result == null || result == s.title) return;
    final before = s.title;
    setState(() => s.title = result); // immediate
    try {
      final stored = await LiveSessionsApi.rename(s.id, result);
      if (mounted) setState(() => s.title = stored);
    } catch (e) {
      if (!mounted) return;
      setState(() => s.title = before);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Rename failed: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _delete(LiveSessionSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete live session?'),
        content: Text('"${s.displayName}" and all its translations will be removed. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await LiveSessionsApi.delete(s.id);
      if (!mounted) return;
      setState(() => _sessions = _sessions.where((x) => x.id != s.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "${s.displayName}"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ─── folders ─────────────────────────────────────────────────────
  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? Colors.red : null,
    ));
  }

  String _apiError(http.Response r) {
    try {
      final b = jsonDecode(r.body);
      if (b is Map && b['error'] != null) return b['error'].toString();
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }

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

  Future<String?> _askFolderName(
      {String title = 'New folder', String initial = ''}) {
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
    // Controller left to the GC (disposing races the closing animation).
  }

  /// Creates [name] on the backend. true if it exists afterwards.
  Future<bool> _ensureFolder(String name) async {
    if (_folders.contains(name)) return true;
    try {
      final r = await http.post(
        Uri.parse('$authBaseUrl/api/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      );
      if (r.statusCode == 201 || r.statusCode == 409) {
        await _fetchFolders();
        return true;
      }
      _snack(_apiError(r), error: true);
    } catch (e) {
      _snack('Could not create folder: $e', error: true);
    }
    return false;
  }

  Future<void> _createFolder() async {
    final name = await _askFolderName();
    if (name == null || name.isEmpty) return;
    if (await _ensureFolder(name)) _setFolderFilter(name);
  }

  Future<void> _renameFolder(String oldName) async {
    final name =
        await _askFolderName(title: 'Rename folder', initial: oldName);
    if (name == null || name.isEmpty || name == oldName) return;
    try {
      final r = await http.put(
        Uri.parse('$authBaseUrl/api/folders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'old': oldName, 'new': name}),
      );
      if (r.statusCode != 200) {
        _snack(_apiError(r), error: true);
        return;
      }
      setState(() {
        for (final s in _sessions) {
          if (s.folder == oldName) s.folder = name;
        }
      });
      await _fetchFolders();
      _setFolderFilter(name);
    } catch (e) {
      _snack('Could not rename folder: $e', error: true);
    }
  }

  Future<void> _deleteFolder(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete folder?'),
        content: Text('Nothing inside "$name" is deleted — its live sessions '
            'and videos move to "Unsorted".'),
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
      final r = await http.delete(Uri.parse(
          '$authBaseUrl/api/folders?name=${Uri.encodeQueryComponent(name)}'));
      if (r.statusCode != 200) {
        _snack(_apiError(r), error: true);
        return;
      }
      setState(() {
        for (final s in _sessions) {
          if (s.folder == name) s.folder = null;
        }
      });
      await _fetchFolders();
      _setFolderFilter(null);
    } catch (e) {
      _snack('Could not delete folder: $e', error: true);
    }
  }

  Future<void> _moveToFolder(LiveSessionSummary s, String? folder) async {
    if (s.folder == folder) return;
    if (folder != null && !await _ensureFolder(folder)) return;
    final before = s.folder;
    setState(() => s.folder = folder); // immediate
    try {
      await LiveSessionsApi.moveToFolder(s.id, folder);
      _snack(folder == null
          ? '"${s.displayName}" moved to Unsorted'
          : '"${s.displayName}" moved to "$folder"');
    } catch (e) {
      if (mounted) setState(() => s.folder = before);
      _snack('Could not move session: $e', error: true);
    }
  }

  Future<void> _pickFolderFor(LiveSessionSummary s) async {
    const newFolder = '\u0000new';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move "${s.displayName}" to'),
        children: [
          for (final f in _folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Row(children: [
                Icon(s.folder == f ? Icons.folder : Icons.folder_outlined,
                    size: 20, color: Colors.amber.shade800),
                const SizedBox(width: 10),
                Expanded(child: Text(f, overflow: TextOverflow.ellipsis)),
                if (s.folder == f) const Icon(Icons.check, size: 18),
              ]),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _unsortedFilter),
            child: Row(children: [
              const Icon(Icons.inbox_outlined, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Text('Unsorted (no folder)')),
              if (s.folder == null) const Icon(Icons.check, size: 18),
            ]),
          ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, newFolder),
            child: const Row(children: [
              Icon(Icons.create_new_folder_outlined,
                  size: 20, color: Colors.blue),
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
      await _moveToFolder(s, name);
      return;
    }
    await _moveToFolder(s, choice == _unsortedFilter ? null : choice);
  }

  /// "All · Unsorted · folders…" chips. Folder chips accept dragged
  /// session cards (wide screens).
  Widget _buildFolderBar() {
    Widget chip({
      required String label,
      required int count,
      required bool selected,
      required IconData icon,
      required VoidCallback onTap,
      String? dropKey,
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
          final s = _sessions.where((x) => x.id == d.data).firstOrNull;
          if (s != null) {
            _moveToFolder(s, dropKey == _unsortedFilter ? null : dropKey);
          }
        },
        builder: (_, __, ___) => c(_dropHover == dropKey),
      );
    }

    final selectedFolder =
        (_folderFilter != null && _folderFilter != _unsortedFilter)
            ? _folderFilter
            : null;

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        chip(
          label: 'All sessions',
          count: _sessions.length,
          selected: _folderFilter == null,
          icon: Icons.mic_none,
          onTap: () => _setFolderFilter(null),
        ),
        chip(
          label: 'Unsorted',
          count: _sessions.where((s) => s.folder == null).length,
          selected: _folderFilter == _unsortedFilter,
          icon: Icons.inbox_outlined,
          onTap: () => _setFolderFilter(_unsortedFilter),
          dropKey: _unsortedFilter,
        ),
        for (final f in _folders)
          chip(
            label: f,
            count: _sessions.where((s) => s.folder == f).length,
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

  // ═══════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final pad = _pad(context);
    final q = _search.trim().toLowerCase();
    final inFolder = _folderFilter == null
        ? _sessions
        : _sessions
            .where((s) => _folderFilter == _unsortedFilter
                ? s.folder == null
                : s.folder == _folderFilter)
            .toList();
    final visible = q.isEmpty
        ? inFolder
        : inFolder
            .where((s) =>
                s.name.toLowerCase().contains(q) ||
                s.title.toLowerCase().contains(q) ||
                s.preview.toLowerCase().contains(q))
            .toList();

    final body = RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ─── Server + connection (top of every page) ───
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
              sliver: const SliverToBoxAdapter(child: ServerConnectionPanel()),
            ),
            if (widget.top != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
                sliver: SliverToBoxAdapter(child: widget.top),
              ),
            ..._listSlivers(pad, q, visible),
          ],
        ),
      );
    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Sessions'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          const UiModeToggle(),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }

  List<Widget> _listSlivers(
      double pad, String q, List<LiveSessionSummary> visible) {
    return [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 8),
              sliver: SliverToBoxAdapter(child: _buildHeader(context)),
            ),
            if (!_loading && !_needsConnect && _error == null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
                sliver: SliverToBoxAdapter(child: _buildFolderBar()),
              ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_needsConnect)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildConnectState(),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildMessage(
                  icon: Icons.cloud_off,
                  title: 'Could not load live sessions',
                  text: _error!,
                  action: FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ),
              )
            else if (_sessions.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildMessage(
                  icon: Icons.mic_none,
                  title: 'No live sessions yet',
                  text: 'Start a new live session — finished sessions are '
                      'saved here automatically.',
                ),
              )
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: q.isEmpty
                    ? _buildMessage(
                        icon: Icons.folder_open,
                        title: 'This folder is empty',
                        text: 'Move live sessions here with the folder button '
                            'on a session, or drag a session onto the folder.',
                      )
                    : _buildMessage(
                        icon: Icons.search_off,
                        title: 'No matches',
                        text: 'No live session matches "$_search".',
                      ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, pad + 24),
                sliver: SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _buildSessionCard(visible[i]),
                ),
              ),
    ];
  }

  Widget _buildHeader(BuildContext c) {
    final newButton = FilledButton.icon(
      onPressed: _newSession,
      icon: const Icon(Icons.mic),
      label: const Text('New live session'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );

    final search = TextField(
      decoration: const InputDecoration(
        hintText: 'Search live sessions…',
        prefixIcon: Icon(Icons.search),
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (v) => setState(() => _search = v),
    );

    final count = Text(
      _loading || _needsConnect
          ? ''
          : '${_sessions.length} finished session'
              '${_sessions.length == 1 ? '' : 's'}'
              '${UiMode.isExpert ? ' · ${labelForServer(internalServerUrl)}' : ''}',
      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
    );

    if (_isNarrow(c)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          newButton,
          const SizedBox(height: 12),
          search,
          const SizedBox(height: 6),
          count,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            newButton,
            const SizedBox(width: 16),
            Expanded(child: search),
          ],
        ),
        const SizedBox(height: 6),
        count,
      ],
    );
  }

  /// Card, draggable onto a folder chip on wide screens (on phones a
  /// drag would fight the list scrolling — use the folder button there).
  Widget _buildSessionCard(LiveSessionSummary s) {
    final card = _buildSessionCardBody(s);
    if (_isNarrow(context)) return card;
    return Draggable<String>(
      data: s.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        color: Colors.blue.shade700,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.record_voice_over, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(s.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white)),
            ),
          ]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }

  Widget _buildSessionCardBody(LiveSessionSummary s) {
    final langs = <String>[
      ...s.inputLanguages.map(LanguageConfig.getDisplayName),
    ].join(', ');
    final outs = s.outputLanguages.map(LanguageConfig.getDisplayName).join(', ');

    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: Colors.blue.shade50,
                child: Icon(Icons.record_voice_over,
                    color: Colors.blue.shade700, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.displayName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: s.title.isEmpty
                              ? 'Give this session a name'
                              : 'Rename',
                          icon: Icon(Icons.edit_outlined,
                              size: 16, color: Colors.grey.shade600),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          onPressed: () => _rename(s),
                        ),
                      ],
                    ),
                    if (s.title.isNotEmpty)
                      Text(
                        s.name,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      children: [
                        if (s.folder != null && _folderFilter == null)
                          _meta(Icons.folder_outlined, s.folder!),
                        _meta(Icons.event, formatDateTime(s.createdAt)),
                        _meta(Icons.timer_outlined, formatDuration(s.duration)),
                        if (UiMode.isExpert)
                          _meta(Icons.notes, '${s.wordCount} words'),
                        // Spoken language(s) of the talk.
                        if (langs.isNotEmpty) _meta(Icons.mic_none, langs),
                      ],
                    ),
                    // Everything the session produced: link, translations,
                    // spoken translations.
                    if (s.permanentName.isNotEmpty ||
                        outs.isNotEmpty ||
                        s.ttsLanguages.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 2,
                        children: [
                          if (s.permanentName.isNotEmpty)
                            _permanentNameChip(s),
                          if (outs.isNotEmpty)
                            _meta(Icons.translate, outs),
                          if (s.ttsLanguages.isNotEmpty)
                            _meta(
                              Icons.record_voice_over_outlined,
                              'TTS: ${s.ttsLanguages.map(LanguageConfig.getDisplayName).join(', ')}',
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: s.folder == null
                    ? 'Move to folder'
                    : 'Folder: ${s.folder} — move',
                icon: Icon(
                  s.folder == null ? Icons.drive_file_move_outline : Icons.folder,
                  color: Colors.amber.shade800,
                ),
                onPressed: () => _pickFolderFor(s),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                onPressed: () => _delete(s),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Permanent name; tap copies the <server>/webapi/shorten/<name> link.
  Widget _permanentNameChip(LiveSessionSummary s) {
    final server = (s.server.isNotEmpty ? s.server : internalServerUrl)
        .replaceAll(RegExp(r'/+$'), '');
    final link = '$server/webapi/shorten/${s.permanentName}';
    return Tooltip(
      message: '$link\nClick to copy',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: link));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Link copied: $link')),
          );
        },
        child: _meta(Icons.link, s.permanentName),
      ),
    );
  }

  /// Icon + text; long text (e.g. many languages) wraps onto further
  /// lines instead of running past the card's edge.
  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              text,
              softWrap: true,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
        ],
      );

  Widget _buildConnectState() {
    return _buildMessage(
      icon: Icons.link_off,
      title: 'Not connected',
      text: 'Connect to ${labelForServer(internalServerUrl)} with the panel '
          'above (Connect or Manual Token) to see your live sessions and '
          'start new ones.',
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String text,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
              if (action != null) ...[
                const SizedBox(height: 16),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
