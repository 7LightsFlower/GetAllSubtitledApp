// widgets/transcript_view.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/models/session_data.dart';

class TranscriptView extends StatefulWidget {
  final TranscriptData transcript;
  final int highlightedIndex;
  final ScrollController? scrollController;
  final String? title;

  /// Show the Running text / Lines button inside the panel. Screens that
  /// put a [TranscriptModeToggle] in their own toolbar pass false.
  final bool showModeToggle;

  /// Running text (true, default) or one line per segment with
  /// timestamps. Shared by all transcript panels while the app is open.
  static final ValueNotifier<bool> fluentMode = ValueNotifier<bool>(true);

  const TranscriptView({
    super.key,
    required this.transcript,
    required this.highlightedIndex,
    this.scrollController,
    this.title,
    this.showModeToggle = true,
  });

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final GlobalKey _highlightKey = GlobalKey();

  static ValueNotifier<bool> get _fluent => TranscriptView.fluentMode;

  @override
  void initState() {
    super.initState();
    _fluent.addListener(_onModeChanged);
  }

  @override
  void dispose() {
    _fluent.removeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightedIndex != oldWidget.highlightedIndex &&
        widget.highlightedIndex >= 0) {
      _scrollToHighlighted();
    }
  }

  void _scrollToHighlighted() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _highlightKey.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.transcript.segments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.text_fields, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              'No transcript available',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.title != null || widget.showModeToggle)
          Container(
            padding: EdgeInsets.fromLTRB(12, widget.title != null ? 4 : 0, 4,
                widget.title != null ? 4 : 0),
            decoration: BoxDecoration(
              color: widget.title != null ? Colors.blue.shade50 : null,
              border: Border(
                bottom: BorderSide(
                    color: widget.title != null
                        ? Colors.blue.shade200
                        : Colors.grey.shade200),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: widget.title == null
                      ? const SizedBox.shrink()
                      : Text(
                          widget.title!,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade800,
                          ),
                        ),
                ),
                if (widget.showModeToggle) _modeToggle(),
              ],
            ),
          ),
          Expanded(
            child: _fluent.value ? _buildFluent() : ListView.builder(
              controller: widget.scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.transcript.segments.length,
              itemBuilder: (context, index) {
                final segment = widget.transcript.segments[index];
                final isHighlighted = index == widget.highlightedIndex;
                
                return Container(
                  key: isHighlighted ? _highlightKey : null,
                  child: _buildSegmentItem(segment, isHighlighted, index,
                      previousSpeaker: _previousSpeaker(index)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeToggle() {
    final fluent = _fluent.value;
    return TextButton.icon(
      onPressed: () => _fluent.value = !fluent,
      icon: Icon(fluent ? Icons.format_list_bulleted : Icons.notes, size: 16),
      label: Text(fluent ? 'Lines' : 'Running text',
          style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  bool _isPlainSegment(SegmentData s) =>
      s.markup == null || s.markup == 'paragraphBreak' || s.markup == 'heading';

  /// Running text: segments flow on in one paragraph; a new paragraph
  /// starts when the speaker changes or KIT marks a paragraph break.
  /// Summaries / notes keep their boxes. The segment being played is
  /// highlighted inside the paragraph.
  Widget _buildFluent() {
    final segs = widget.transcript.segments;
    final blocks = <Widget>[];
    var spans = <InlineSpan>[];
    var lastChar = -1;
    var speaker = '';
    var hasHighlight = false;

    void flush() {
      if (spans.isEmpty) return;
      blocks.add(Padding(
        key: hasHighlight ? _highlightKey : null,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Text.rich(
          TextSpan(
            style: TextStyle(
                fontSize: 14, height: 1.5, color: Colors.grey.shade900),
            children: spans,
          ),
        ),
      ));
      spans = <InlineSpan>[];
      lastChar = -1;
      hasHighlight = false;
    }

    for (var i = 0; i < segs.length; i++) {
      final seg = segs[i];
      final text = seg.text.trim();
      if (text.isEmpty) continue;
      if (text.contains('<br') || seg.markup == 'paragraphBreak') {
        flush();
        continue;
      }
      if (!_isPlainSegment(seg)) {
        flush();
        blocks.add(_buildSpecialMarkup(seg));
        continue;
      }
      final name = displaySpeakerName(seg.speakerName);
      if (name.isNotEmpty && name != speaker) {
        flush();
        speaker = name;
        blocks.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade800,
                ),
              ),
            ),
          ),
        ));
      }
      if (seg.markup == 'heading') {
        flush();
        blocks.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(text,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ));
        continue;
      }
      // Space between segments, except inside CJK / Thai text.
      if (lastChar >= 0 && !(_noSpace(lastChar) && _noSpace(text.codeUnitAt(0)))) {
        spans.add(const TextSpan(text: ' '));
      }
      final isHi = i == widget.highlightedIndex;
      if (isHi) hasHighlight = true;
      spans.add(TextSpan(
        text: text,
        style: isHi
            ? TextStyle(
                backgroundColor: Colors.yellow.shade200,
                color: Colors.black,
              )
            : null,
      ));
      lastChar = text.codeUnitAt(text.length - 1);
    }
    flush();

    return SelectionArea(
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: blocks,
      ),
    );
  }

  static bool _noSpace(int c) =>
      (c >= 0x3000 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFF00 && c <= 0xFFEF) ||
      (c >= 0x0E00 && c <= 0x0E7F);

  /// Speaker of the nearest earlier segment that is actually shown.
  String _previousSpeaker(int index) {
    final segs = widget.transcript.segments;
    for (var i = index - 1; i >= 0; i--) {
      final s = segs[i];
      if (s.text.isEmpty || s.text.contains('<br')) continue;
      final name = displaySpeakerName(s.speakerName);
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  Widget _buildSegmentItem(SegmentData segment, bool isHighlighted, int index,
      {String previousSpeaker = ''}) {
    // Skip empty segments
    if (segment.text.isEmpty || segment.text.contains('<br')) {
      return const SizedBox.shrink();
    }

    // Speaker chip only when the speaker actually changes.
    final speaker = displaySpeakerName(segment.speakerName);
    final isSpeakerChange = speaker.isNotEmpty && speaker != previousSpeaker;

    // Check if this is a markup element
    final isSpecialMarkup = segment.markup != null && 
        segment.markup != 'paragraphBreak' && 
        segment.markup != 'heading';

    // If it's a special markup, render differently
    if (isSpecialMarkup) {
      return _buildSpecialMarkup(segment);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isHighlighted 
            ? Colors.yellow.shade100 
            : (index % 2 == 0 ? Colors.grey.shade50 : Colors.white),
        border: isHighlighted
            ? Border(
                left: BorderSide(color: Colors.blue.shade700, width: 3),
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSpeakerChange)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      speaker,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 50,
                  child: Text(
                    '${segment.start.toStringAsFixed(1)}s',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    segment.text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      fontWeight: isHighlighted ? FontWeight.w600 : FontWeight.normal,
                      color: isHighlighted ? Colors.black : Colors.grey.shade800,
                    ),
                    softWrap: true, // ✅ Add this to prevent overflow
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpecialMarkup(SegmentData segment) {
    if (segment.markup == 'summary') {
      return Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.summarize, size: 16, color: Colors.green.shade700),
                const SizedBox(width: 8),
                Text(
                  'Summary',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              segment.text,
              style: const TextStyle(fontSize: 14),
              softWrap: true, // ✅ Add this
            ),
          ],
        ),
      );
    }

    if (segment.markup == 'global_summary') {
      return Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.purple.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.purple.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.summarize, size: 16, color: Colors.purple.shade700),
                const SizedBox(width: 8),
                Text(
                  'Global Summary',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.purple.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              segment.text,
              style: const TextStyle(fontSize: 14),
              softWrap: true, // ✅ Add this
            ),
          ],
        ),
      );
    }

    if (segment.markup == 'postedited') {
      return Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit, size: 16, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Text(
                  'Post-Edited',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              segment.text,
              style: const TextStyle(fontSize: 14),
              softWrap: true, // ✅ Add this
            ),
          ],
        ),
      );
    }

    if (segment.markup == 'notes') {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.note, size: 14, color: Colors.blue.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                segment.text,
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: Colors.blue.shade800,
                ),
                softWrap: true, // ✅ Add this (already wrapped in Expanded)
              ),
            ),
          ],
        ),
      );
    }

    // Default fallback for other markup types
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        segment.text,
        softWrap: true, // ✅ Add this
      ),
    );
  }
}


/// One button that flips between two views. It shows the current view
/// (icon + label on wide screens) with a small ⇄ to say "tap to switch".
class ViewToggleButton extends StatelessWidget {
  const ViewToggleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;

  /// null = disabled.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final enabled = onTap != null;
    final fg = enabled ? Colors.blue.shade800 : Colors.grey.shade400;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: enabled ? Colors.blueGrey.shade50 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: wide ? 10 : 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: fg),
                  if (wide) ...[
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(Icons.swap_horiz, size: 14,
                      color: fg.withValues(alpha: 0.6)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Running text ⇄ Lines as one switch button, for a screen's own
/// toolbar (pair it with `TranscriptView(showModeToggle: false)`).
class TranscriptModeToggle extends StatelessWidget {
  const TranscriptModeToggle({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TranscriptView.fluentMode,
      builder: (context, fluent, _) => ViewToggleButton(
        icon: fluent ? Icons.notes : Icons.format_list_bulleted,
        label: fluent ? 'Running text' : 'Lines',
        tooltip: fluent
            ? 'Running text — tap for one line per segment with time'
            : 'Lines — tap for running text',
        onTap: enabled
            ? () => TranscriptView.fluentMode.value = !fluent
            : null,
      ),
    );
  }
}
