// lib/widgets/job_progress_panel.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/models/job_progress.dart';

/// Polls the server every [pollInterval] and shows live processing state
/// for a session. Drop this anywhere you have a session_id.
class JobProgressPanel extends StatefulWidget {
  final String sessionId;
  final Duration pollInterval;
  final VoidCallback? onComplete;
  final bool compact;

  const JobProgressPanel({
    super.key,
    required this.sessionId,
    this.pollInterval = const Duration(seconds: 1),
    this.onComplete,
    this.compact = false,
  });

  @override
  State<JobProgressPanel> createState() => _JobProgressPanelState();
}

class _JobProgressPanelState extends State<JobProgressPanel> {
  Timer? _timer;
  JobProgress _progress = JobProgress.empty;
  final ScrollController _logScroll = ScrollController();
  bool _completedNotified = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  int _pollCount = 0;

  Future<void> _poll() async {
    if (!mounted) return;
    _pollCount++;

    // Hard cap: ~5 minutes at 1s interval, then give up.
    if (_pollCount > 300) {
      _timer?.cancel();
      if (!_completedNotified) {
        _completedNotified = true;
        widget.onComplete?.call();
      }
      return;
    }
    try {
      final encoded = Uri.encodeComponent(widget.sessionId);
      final resp = await http.get(
        Uri.parse('$flaskServerUrl/job_progress/$encoded'),
      );
      if (resp.statusCode != 200 || !mounted) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final next = JobProgress.fromJson(data);

      setState(() => _progress = next);

      // Auto-scroll the log
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });

      if (next.done && !_completedNotified) {
        _completedNotified = true;
        _timer?.cancel();
        widget.onComplete?.call();
      }
    } catch (_) {
      // transient — keep polling
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                _stageIcon(p),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _stageLabel(p),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (p.done && p.error == null)
                  const Chip(
                    label: Text('Ready', style: TextStyle(fontSize: 11)),
                    backgroundColor: Color(0xFFD7F5D9),
                    visualDensity: VisualDensity.compact,
                  )
                else if (p.error != null)
                  Chip(
                    label: const Text('Failed',
                        style: TextStyle(fontSize: 11)),
                    backgroundColor: Colors.red.shade100,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // Progress bar
            LinearProgressIndicator(
              value: p.progress.clamp(0.0, 1.0),
              minHeight: 6,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    p.message,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[700],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(p.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // File counter
            Row(
              children: [
                Icon(Icons.folder_open,
                    size: 14, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '${p.files.length} files downloaded',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Log console
            Container(
              height: widget.compact ? 140 : 220,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(8),
              child: p.events.isEmpty
                  ? const Center(
                      child: Text(
                        'Waiting for server…',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _logScroll,
                      itemCount: p.events.length,
                      itemBuilder: (ctx, i) {
                        final ev = p.events[i];
                        return Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 1),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.35,
                              ),
                              children: [
                                TextSpan(
                                  text: '${ev.time}  ',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                  ),
                                ),
                                TextSpan(
                                  text: _iconFor(ev.level),
                                  style: TextStyle(
                                    color: _colorFor(ev.level),
                                  ),
                                ),
                                const TextSpan(text: ' '),
                                TextSpan(
                                  text: ev.message,
                                  style: TextStyle(
                                    color: _colorFor(ev.level),
                                  ),
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
    );
  }

  Widget _stageIcon(JobProgress p) {
    if (p.error != null) {
      return const Icon(Icons.error_outline, color: Colors.red);
    }
    if (p.done) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    return const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  String _stageLabel(JobProgress p) {
    if (p.error != null) return 'Processing failed';
    if (p.done) return 'Processing complete';
    switch (p.stage) {
      case 'starting':
        return 'Preparing…';
      case 'waiting':
        return 'Waiting for the server';
      case 'downloading':
        return 'Downloading session files';
      case 'extracting':
        return 'Extracting transcripts';
      case 'ready':
        return 'Finalising';
      default:
        return 'Processing';
    }
  }

  String _iconFor(String level) {
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
}