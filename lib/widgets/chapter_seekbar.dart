// widgets/chapter_seekbar.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/models/session_data.dart';

class ChapterSeekbar extends StatefulWidget {
  final List<ChapterData> chapters;
  final double currentTime;
  final Function(ChapterData) onTap;

  const ChapterSeekbar({
    super.key,
    required this.chapters,
    required this.currentTime,
    required this.onTap,
  });

  @override
  State<ChapterSeekbar> createState() => _ChapterSeekbarState();
}

class _ChapterSeekbarState extends State<ChapterSeekbar> {
  int _hoveredChapterIndex = -1;

  // Palette — matches the dark video pane and mirrors the greens used
  // for the active/played portion of a typical scrubber.
  static const Color _base    = Color(0xFF2A2A2A);
  static const Color _hover   = Color(0xFF2E7D32); // green.shade800
  static const Color _active  = Color(0xFF388E3C); // green.shade700
  static const Color _played  = Color(0xFF66BB6A); // green.shade400

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) return const SizedBox.shrink();

    final totalDuration = widget.chapters.last.end;
    if (totalDuration <= 0) return const SizedBox.shrink();

    return Row(
      children: widget.chapters.asMap().entries.map((entry) {
        final index = entry.key;
        final chapter = entry.value;
        final width =
            ((chapter.end - chapter.start) / totalDuration * 100)
                .clamp(1.0, 100.0);
        final isActive = widget.currentTime >= chapter.start &&
            widget.currentTime < chapter.end;
        final isHovered = _hoveredChapterIndex == index;

        return Expanded(
          flex: width.toInt(),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoveredChapterIndex = index),
            onExit: (_) => setState(() => _hoveredChapterIndex = -1),
            child: GestureDetector(
              onTap: () => widget.onTap(chapter),
              child: Container(
                // 1 px black gutter between chapters so they read as
                // discrete blocks without a chunky border.
                margin: const EdgeInsets.symmetric(horizontal: 0.5),
                color: isActive
                    ? _active
                    : isHovered
                        ? _hover
                        : _base,
                child: isActive && widget.currentTime > chapter.start
                    ? FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor:
                            ((widget.currentTime - chapter.start) /
                                    (chapter.end - chapter.start))
                                .clamp(0.0, 1.0),
                        child: const ColoredBox(color: _played),
                      )
                    : null,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}