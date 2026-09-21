// video_player_widget.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:asr_live_translator/models/subtitle_track.dart';

class VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerController? controller;
  final bool isReady;
  final VoidCallback onPlayPause;
  final Function(double) onSeek;
  final double height;
  final List<SubtitleTrack>? subtitleTracks;
  final String? selectedSubtitle;
  final Function(String?)? onSubtitleChanged;

  const VideoPlayerWidget({
    super.key,
    required this.controller,
    required this.isReady,
    required this.onPlayPause,
    required this.onSeek,
    required this.height,
    this.subtitleTracks,
    this.selectedSubtitle,
    this.onSubtitleChanged,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  bool _isDragging = false;
  double _currentPosition = 0.0;

  @override
  Widget build(BuildContext context) {
    if (!widget.isReady || widget.controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final controller = widget.controller!;
    final duration = controller.value.duration;
    final position = controller.value.position;
    _currentPosition = position.inSeconds.toDouble();

    final hasSubtitles =
        widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // ─── Video pane ──────────────────────────────────────────────
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Video
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),

              // Play/Pause overlay button
              Center(
                child: IconButton(
                  icon: Icon(
                    controller.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                    color: Colors.white.withValues(alpha: 0.7),
                    size: 48,
                  ),
                  onPressed: widget.onPlayPause,
                ),
              ),

              // ─── Subtitle selector — floating pill, top-right ──────
              if (hasSubtitles)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _buildSubtitleSelector(),
                ),
            ],
          ),
        ),

        // ─── Bottom controls — progress slider only ─────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.black.withValues(alpha: 0.6),
          child: Row(
            children: [
              Text(
                _formatDuration(position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _isDragging
                      ? _currentPosition
                      : position.inSeconds.toDouble(),
                  min: 0,
                  max: duration.inSeconds.toDouble(),
                  onChanged: (value) {
                    setState(() {
                      _isDragging = true;
                      _currentPosition = value;
                    });
                  },
                  onChangeEnd: (value) {
                    _isDragging = false;
                    widget.onSeek(value);
                  },
                  activeColor: Colors.blue,
                  inactiveColor: Colors.grey,
                ),
              ),
              Text(
                _formatDuration(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubtitleSelector() {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.closed_caption,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: widget.selectedSubtitle,
                  isDense: true,
                  isExpanded: false,
                  dropdownColor: Colors.grey[900],
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text(
                        'Off',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                    ...widget.subtitleTracks!.map((track) {
                      return DropdownMenuItem<String>(
                        value: track.language,
                        child: Text(
                          track.label,
                          style: const TextStyle(color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    widget.onSubtitleChanged?.call(value);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (duration.inHours > 0) {
      final hours = duration.inHours;
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}