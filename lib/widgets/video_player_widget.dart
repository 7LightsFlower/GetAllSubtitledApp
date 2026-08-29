// widgets/video_player_widget.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerController? controller;
  final bool isReady;
  final VoidCallback onPlayPause;
  final Function(double) onSeek;
  final double? height; // Optional height parameter

  const VideoPlayerWidget({
    super.key,
    required this.controller,
    required this.isReady,
    required this.onPlayPause,
    required this.onSeek,
    this.height,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  bool _showControls = true;

  @override
  Widget build(BuildContext context) {
    if (!widget.isReady || widget.controller == null) {
      return SizedBox(
        height: widget.height ?? 200,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _showControls = !_showControls;
        });
      },
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Video fills the container with proper aspect ratio
            Center(
              child: AspectRatio(
                aspectRatio: widget.controller!.value.aspectRatio,
                child: VideoPlayer(widget.controller!),
              ),
            ),
            
            // Play/Pause overlay button
            if (_showControls)
              Container(
                color: Colors.transparent,
                child: IconButton(
                  icon: Icon(
                    widget.controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 48,
                  ),
                  onPressed: widget.onPlayPause,
                ),
              ),
            
            // Bottom controls
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildControls(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final controller = widget.controller!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 20,
            ),
            onPressed: widget.onPlayPause,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              value: controller.value.position.inSeconds.toDouble(),
              max: controller.value.duration.inSeconds.toDouble(),
              onChanged: (value) {
                widget.onSeek(value);
              },
              activeColor: Colors.blue,
              inactiveColor: Colors.white30,
              thumbColor: Colors.blue,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(controller.value.position),
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          const SizedBox(width: 4),
          Text(
            _formatDuration(controller.value.duration),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              controller.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
              color: Colors.white,
              size: 18,
            ),
            onPressed: () {
              controller.setVolume(
                controller.value.volume == 0 ? 1 : 0,
              );
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
