// live_sessions_screen.dart
//
// Entry screen for live speech recognition, opened from the mic button
// on the working screen:
//
//   Working screen ──► Live Sessions (this) ──► New live session
//                                         └──► finished session (read-only)
//
// Lists the user's finished live sessions saved on the backend
// (/api/live/saved), newest first.

import 'dart:js_interop';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/screens/live_asr_screen.dart';
import 'package:asr_live_translator/screens/live_session_view_screen.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:asr_live_translator/services/live_sessions_api.dart';
import 'package:asr_live_translator/services/server_config_service.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class LiveSessionsScreen extends StatefulWidget {
  const LiveSessionsScreen({super.key});

  @override
  State<LiveSessionsScreen> createState() => _LiveSessionsScreenState();
}

class _LiveSessionsScreenState extends State<LiveSessionsScreen> {
  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;
  double _pad(BuildContext c) => _isNarrow(c) ? 12 : 24;

  List<LiveSessionSummary> _sessions = const [];
  bool _loading = true;
  String? _error;
  bool _needsConnect = false;
  bool _connecting = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _init();
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
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LiveAsrScreen()),
    );
    if (mounted) _load();
  }

  Future<void> _open(LiveSessionSummary s) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => LiveSessionViewScreen(sessionId: s.id)),
    );
    if (deleted == true && mounted) _load();
  }

  Future<void> _delete(LiveSessionSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete live session?'),
        content: Text('"${s.name}" and all its translations will be removed. '
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
        SnackBar(content: Text('Deleted "${s.name}"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ─── connection (only shown when the token is missing) ───────────
  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      await InternalAuthService.loginWithOAuth();
    } catch (_) {}
    if (mounted) setState(() => _connecting = false);
    await _load();
  }

  Future<void> _pasteToken() async {
    try {
      final raw =
          (await web.window.navigator.clipboard.readText().toDart).toDart;
      final m = RegExp(r"([^\s'<>|]+\|\d{10}\|[^\s'<>]+)").firstMatch(raw);
      final token = (m?.group(1) ?? raw).trim();
      if (token.isEmpty) throw 'Clipboard is empty';
      await InternalAuthService.setManualToken(token);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not paste token: $e')),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final pad = _pad(context);
    final q = _search.trim().toLowerCase();
    final visible = q.isEmpty
        ? _sessions
        : _sessions
            .where((s) =>
                s.name.toLowerCase().contains(q) ||
                s.preview.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Sessions'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 8),
              sliver: SliverToBoxAdapter(child: _buildHeader(context)),
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
                child: _buildMessage(
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
          ],
        ),
      ),
    );
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
              '${_sessions.length == 1 ? '' : 's'} · '
              '${labelForServer(internalServerUrl)}',
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

  Widget _buildSessionCard(LiveSessionSummary s) {
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
                    Text(
                      s.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      children: [
                        _meta(Icons.event, formatDateTime(s.createdAt)),
                        _meta(Icons.timer_outlined, formatDuration(s.duration)),
                        _meta(Icons.notes, '${s.wordCount} words'),
                        _meta(
                          Icons.translate,
                          outs.isEmpty ? langs : '$langs → $outs',
                        ),
                      ],
                    ),
                    if (s.preview.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        s.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade800,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
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

  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.grey.shade600),
          const SizedBox(width: 3),
          Text(text,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ],
      );

  Widget _buildConnectState() {
    return _buildMessage(
      icon: Icons.link_off,
      title: 'Not connected',
      text: 'Connect to ${labelForServer(internalServerUrl)} to see your '
          'live sessions and start new ones.',
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _connecting ? null : _connect,
            icon: _connecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login, size: 18),
            label: const Text('Connect'),
          ),
          OutlinedButton.icon(
            onPressed: () => web.window
                .open('$internalServerUrl/gettoken', 'gettoken_tab'),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Get Token'),
          ),
          OutlinedButton.icon(
            onPressed: _pasteToken,
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('Paste Token'),
          ),
        ],
      ),
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
