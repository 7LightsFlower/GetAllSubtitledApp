// job_progress_panel.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';

class JobProgressPanel extends StatefulWidget {
  final String sessionId;
  final VoidCallback? onComplete;

  const JobProgressPanel({
    super.key,
    required this.sessionId,
    this.onComplete,
  });

  @override
  State<JobProgressPanel> createState() => _JobProgressPanelState();
}

class _JobProgressPanelState extends State<JobProgressPanel> {
  static const Duration _pollInterval = Duration(seconds: 2);

  Timer? _timer;
  final ScrollController _scroll = ScrollController();

  bool _loading = true;
  String? _error;

  double _progress = 0.0;
  String _stage = '';
  String _message = '';
  bool _done = false;
  List<Map<String, dynamic>> _events = [];

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (!mounted) return;
    try {
      final token = await InternalAuthService.getToken();
      if (token == null || token.isEmpty) return;
      final url = '$flaskServerUrl/job-progress/${widget.sessionId}';
      final resp = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() {
          _error = 'HTTP ${resp.statusCode}';
          _loading = false;
        });
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final events = (data['events'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const [];

      final wasDone = _done;
      setState(() {
        _error = null;
        _loading = false;
        _progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
        _stage = data['stage'] as String? ?? '';
        _message = data['message'] as String? ?? '';
        _done = data['done'] == true;
        _events = events;
      });

      // Auto-scroll to the newest event.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });

      if (!wasDone && _done) {
        widget.onComplete?.call();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Color _levelColour(String level) {
    switch (level) {
      case 'error':
        return Colors.red.shade700;
      case 'warning':
        return Colors.orange.shade800;
      default:
        return Colors.grey.shade800;
    }
  }

  IconData _levelIcon(String level) {
    switch (level) {
      case 'error':
        return Icons.error_outline;
      case 'warning':
        return Icons.warning_amber_outlined;
      default:
        return Icons.chevron_right;
    }
  }

  String _stageLabel(String stage) {
    switch (stage) {
      case 'starting':
        return 'Starting';
      case 'transcribing':
        return 'Transcribing';
      case 'translating':
        return 'Translating';
      case 'downloading':
        return 'Downloading';
      case 'extracting':
        return 'Extracting';
      case 'ready':
        return 'Ready';
      case 'cancelled':
        return 'Cancelled';
      case 'error':
        return 'Error';
      case 'complete':
        return 'Complete';
      default:
        return stage.isEmpty ? 'Processing' : stage;
    }
  }

  Color _stageColour(String stage) {
    switch (stage) {
      case 'translating':
        return Colors.indigo;
      case 'transcribing':
        return Colors.deepPurple;
      case 'downloading':
        return Colors.blue;
      case 'ready':
      case 'complete':
        return Colors.green;
      case 'cancelled':
        return Colors.orange;
      case 'error':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: stage badge + percentage
            Row(
              children: [
                Chip(
                  avatar: Icon(
                    _done ? Icons.check_circle : Icons.sync,
                    size: 16,
                    color: Colors.white,
                  ),
                  label: Text(
                    _stageLabel(_stage),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  backgroundColor: _stageColour(_stage),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation(_stageColour(_stage)),
              ),
            ),

            if (_message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _message,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],

            if (_loading) ...[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator()),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                'Polling error: $_error',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ],

            // Event log
            if (_events.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              const Text(
                'Live log',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  itemCount: _events.length,
                  itemBuilder: (ctx, i) {
                    final ev = _events[i];
                    final t = (ev['time'] as String?) ?? '';
                    final lvl = (ev['level'] as String?) ?? 'info';
                    final msg = (ev['message'] as String?) ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            _levelIcon(lvl),
                            size: 14,
                            color: _levelColour(lvl),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              msg,
                              style: TextStyle(
                                fontSize: 12,
                                color: _levelColour(lvl),
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}