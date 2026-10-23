// live_session_view_screen.dart
//
// Read-only view of one finished live session: original transcript and
// translations side by side (wide) or switchable (narrow), with copy,
// download and delete. Pops with `true` when the session was deleted so
// the list can refresh.

import 'dart:js_interop';

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/language_config.dart';
import 'package:asr_live_translator/services/live_sessions_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

class LiveSessionViewScreen extends StatefulWidget {
  const LiveSessionViewScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<LiveSessionViewScreen> createState() => _LiveSessionViewScreenState();
}

class _LiveSessionViewScreenState extends State<LiveSessionViewScreen> {
  bool _isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;
  bool _isWide(BuildContext c) => MediaQuery.sizeOf(c).width >= 1000;
  double _pad(BuildContext c) => _isNarrow(c) ? 12 : 24;

  LiveSessionRecord? _rec;
  String? _error;
  String _selected = 'asr';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rec = await LiveSessionsApi.get(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _rec = rec;
        if (!rec.lanes.any((l) => l.key == _selected) && rec.lanes.isNotEmpty) {
          _selected = rec.lanes.first.key;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete() async {
    final rec = _rec;
    if (rec == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete live session?'),
        content: Text('"${rec.name}" and all its translations will be '
            'removed. This cannot be undone.'),
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
      await LiveSessionsApi.delete(rec.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _copy(SavedLane lane) {
    Clipboard.setData(ClipboardData(text: lane.text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: ${lane.title}')),
    );
  }

  void _download(SavedLane lane) {
    final blob = web.Blob(
      <JSAny>[lane.text.toJS].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    (web.HTMLAnchorElement()
          ..href = url
          ..download = '${_rec!.name}_${lane.key}.txt')
        .click();
    web.URL.revokeObjectURL(url);
  }

  void _downloadAll() {
    final rec = _rec!;
    final buf = StringBuffer()
      ..writeln(rec.name)
      ..writeln('${formatDateTime(rec.createdAt)} · '
          '${formatDuration(rec.duration)}')
      ..writeln();
    for (final l in rec.lanes) {
      buf
        ..writeln('══ ${l.title} ══')
        ..writeln(l.text)
        ..writeln();
    }
    final blob = web.Blob(
      <JSAny>[buf.toString().toJS].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    (web.HTMLAnchorElement()
          ..href = url
          ..download = '${rec.name}_all.txt')
        .click();
    web.URL.revokeObjectURL(url);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    return Scaffold(
      appBar: AppBar(
        title: Text(rec?.name ?? 'Live Session'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          if (rec != null) ...[
            IconButton(
              tooltip: 'Download all languages',
              icon: const Icon(Icons.download),
              onPressed: _downloadAll,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ],
      ),
      body: _error != null
          ? _buildError()
          : rec == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: EdgeInsets.all(_pad(context)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildInfoCard(rec),
                      const SizedBox(height: 12),
                      Expanded(child: _buildLanes(rec)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildError() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      );

  Widget _buildInfoCard(LiveSessionRecord rec) {
    final ins = rec.inputLanguages.map(LanguageConfig.getDisplayName).join(', ');
    final outs =
        rec.outputLanguages.map(LanguageConfig.getDisplayName).join(', ');
    final settings = rec.settings.entries
        .where((e) => e.value != null && e.value.toString().isNotEmpty)
        .toList();

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.record_voice_over, color: Colors.blue.shade700),
          title: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _meta(Icons.event, formatDateTime(rec.createdAt)),
              _meta(Icons.timer_outlined, formatDuration(rec.duration)),
              _meta(Icons.translate, outs.isEmpty ? ins : '$ins → $outs'),
              if (rec.server.isNotEmpty)
                _meta(Icons.dns_outlined, labelForServer(rec.server)),
            ],
          ),
          subtitle: settings.isEmpty
              ? null
              : const Text('Settings used', style: TextStyle(fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in settings)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${e.key}: ${e.value is List ? (e.value as List).join(', ') : e.value}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.grey.shade700),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      );

  Widget _buildLanes(LiveSessionRecord rec) {
    final lanes = rec.lanes;
    if (lanes.isEmpty) {
      return const Center(child: Text('This session has no transcript.'));
    }
    if (_isWide(context) && lanes.length <= 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lanes.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: _buildLanePanel(lanes[i])),
          ],
        ],
      );
    }
    final selected =
        lanes.firstWhere((l) => l.key == _selected, orElse: () => lanes.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final l in lanes)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(l.title),
                    selected: l.key == selected.key,
                    onSelected: (_) => setState(() => _selected = l.key),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _buildLanePanel(selected)),
      ],
    );
  }

  Widget _buildLanePanel(SavedLane lane) {
    final paragraphs =
        lane.text.split('\n').where((p) => p.trim().isNotEmpty).toList();
    final textSize = _isNarrow(context) ? 15.0 : 17.0;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(lane.key == 'asr' ? Icons.hearing : Icons.translate,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lane.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: paragraphs.isEmpty ? null : () => _copy(lane),
                ),
                IconButton(
                  tooltip: 'Download .txt',
                  icon: const Icon(Icons.download, size: 18),
                  onPressed: paragraphs.isEmpty ? null : () => _download(lane),
                ),
              ],
            ),
          ),
          Expanded(
            child: paragraphs.isEmpty
                ? Center(
                    child: Text('(empty)',
                        style: TextStyle(color: Colors.grey.shade500)),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: paragraphs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          paragraphs[i],
                          style: TextStyle(fontSize: textSize, height: 1.4),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
