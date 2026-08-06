// session_detail_screen.dart
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/screens/job_configuration_screen.dart';

// ─── Data model ──────────────────────────────────────────────────────────────

class SessionDetail {
  final String key;
  final String name;
  final String fileName;
  final DateTime uploaded;
  final DateTime? lastOpened;
  final double duration;
  final double fps;
  final int fileSize;
  final int segmentCount;
  final List<String> languages;
  final String? thumbnailUrl;
  final String? videoUrl;
  final List<Segment> segments;

  SessionDetail({
    required this.key,
    required this.name,
    required this.fileName,
    required this.uploaded,
    this.lastOpened,
    required this.duration,
    required this.fps,
    required this.fileSize,
    required this.segmentCount,
    required this.languages,
    this.thumbnailUrl,
    this.videoUrl,
    required this.segments,
  });

  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final segments = (json['segments'] as List?)
            ?.map((e) => Segment.fromJson(e))
            .toList() ??
        [];
    return SessionDetail(
      key: json['key'] as String,
      name: json['name'] as String? ?? 'Untitled',
      fileName: json['file_name'] as String? ?? 'video.mp4',
      uploaded: DateTime.parse(json['uploaded'] as String),
      lastOpened: json['last_opened'] != null
          ? DateTime.parse(json['last_opened'] as String)
          : null,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      fileSize: json['file_size'] as int? ?? 0,
      segmentCount: json['segment_count'] as int? ?? 0,
      languages: (json['languages'] as List?)?.cast<String>() ?? [],
      thumbnailUrl: json['thumbnail_url'] as String?,
      videoUrl: json['video_url'] as String?,
      segments: segments,
    );
  }
}

class Segment {
  final int id;
  final double start;
  final double end;
  final String? language;
  final String? url;

  Segment({
    required this.id,
    required this.start,
    required this.end,
    this.language,
    this.url,
  });

  factory Segment.fromJson(Map<String, dynamic> json) {
    return Segment(
      id: json['id'] as int? ?? 0,
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
      language: json['language'] as String?,
      url: json['url'] as String?,
    );
  }
}

// ─── Screen ────────────────────────────────────────────────────────────────

class LiveTranscriptScreen extends StatefulWidget {
  final String videoKey;

  const LiveTranscriptScreen({super.key, required this.videoKey});

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  SessionDetail? _detail;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token') ?? '';
      final response = await http.get(
        Uri.parse('$authBaseUrl//video_detail/${widget.videoKey}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _detail = SessionDetail.fromJson(data);
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load detail (HTTP ${response.statusCode})');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    await _fetchDetail();
  }

  void _startWork() {
    if (_detail == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JobConfigurationScreen(videoKey: _detail!.key),
      ),
    );
  }

  String _formatDuration(double seconds) {
    final int totalSec = seconds.round();
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      return '$bytes B';
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Detail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Error: $_error', style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _detail == null
                  ? const Center(child: Text('No data'))
                  : _buildContent(),
    );
  }

  Widget _buildContent() {
    final detail = _detail!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumbnail
          if (detail.thumbnailUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                detail.thumbnailUrl!,
                width: double.infinity,
                height: 200,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image, size: 80),
              ),
            ),
          const SizedBox(height: 16),

          // Title & File name
          Text(
            detail.name,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            detail.fileName,
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),

          // Metadata grid
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _infoChip(Icons.calendar_today, 'Uploaded', _formatDate(detail.uploaded)),
              _infoChip(Icons.timer, 'Duration', _formatDuration(detail.duration)),
              _infoChip(Icons.speed, 'FPS', detail.fps.toStringAsFixed(1)),
              _infoChip(Icons.storage, 'Size', _formatBytes(detail.fileSize)),
              _infoChip(Icons.layers, 'Segments', detail.segmentCount.toString()),
              if (detail.lastOpened != null)
                _infoChip(Icons.history, 'Last opened', _formatDate(detail.lastOpened!)),
            ],
          ),
          const SizedBox(height: 24),

          // Languages
          if (detail.languages.isNotEmpty) ...[
            const Text(
              'Languages',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: detail.languages
                  .map((lang) => Chip(label: Text(lang)))
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],

          // Segments
          if (detail.segments.isNotEmpty) ...[
            const Text(
              'Segments',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: detail.segments.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (ctx, index) {
                final seg = detail.segments[index];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text('${index + 1}'),
                  ),
                  title: Text('${_formatDuration(seg.start)} – ${_formatDuration(seg.end)}'),
                  subtitle: seg.language != null ? Text(seg.language!) : null,
                  trailing: seg.url != null
                      ? IconButton(
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Playing segment ${index + 1}'),
                              ),
                            );
                          },
                        )
                      : null,
                );
              },
            ),
          ],

          const SizedBox(height: 24),

          // ── Work button ────────────────────────────────────────────────
          Center(
            child: ElevatedButton.icon(
              onPressed: _startWork,
              icon: const Icon(Icons.work), // fixed icon
              label: const Text('Work on this session'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade700),
          const SizedBox(width: 4),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.normal)),
        ],
      ),
    );
  }
}
