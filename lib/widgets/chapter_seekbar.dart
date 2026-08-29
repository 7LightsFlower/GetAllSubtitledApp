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

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) return const SizedBox.shrink();

    final totalDuration = widget.chapters.last.end;
    if (totalDuration <= 0) return const SizedBox.shrink();

    return Container(
      height: 60, // CHANGED: Much thinner - was 36
      color: Colors.transparent, // CHANGED: Transparent - was black with opacity
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Row(
        children: widget.chapters.asMap().entries.map((entry) {
          final index = entry.key;
          final chapter = entry.value;
          final start = chapter.start;
          final end = chapter.end;
          final width = ((end - start) / totalDuration * 100).clamp(1.0, 100.0);
          final isActive = widget.currentTime >= start && widget.currentTime < end;
          final isHovered = _hoveredChapterIndex == index;

          return Expanded(
            flex: width.toInt(),
            child: MouseRegion(
              onEnter: (_) {
                setState(() {
                  _hoveredChapterIndex = index;
                });
              },
              onExit: (_) {
                setState(() {
                  _hoveredChapterIndex = -1;
                });
              },
              child: GestureDetector(
                onTap: () => widget.onTap(chapter),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  decoration: BoxDecoration(
                    color: isActive 
                        ? Colors.green.shade500 // CHANGED: Green for active
                        : isHovered
                            ? Colors.green.shade200.withValues(alpha: 0.5) // CHANGED: Green on hover
                            : Colors.white.withValues(alpha: 0.2), // CHANGED: Dim white
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(
                      color: isActive 
                          ? Colors.green.shade400 // CHANGED: Green border
                          : Colors.transparent,
                      width: 0.5,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Progress fill within chapter
                      if (isActive && widget.currentTime > start)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: ((widget.currentTime - start) / (end - start) * 100).clamp(0.0, 100.0) / 100 * 
                                   MediaQuery.of(context).size.width * (width / 100),
                            decoration: BoxDecoration(
                              color: Colors.green.shade800.withValues(alpha: 0.5), // CHANGED: Green progress
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      
                      // Chapter number - only show if segment is wide enough
                      if (width > 10)
                        Center(
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: isActive ? Colors.white : Colors.white70,
                              fontSize: 9,
                              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
