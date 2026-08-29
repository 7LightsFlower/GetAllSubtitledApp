// widgets/transcript_view.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/models/session_data.dart';

class TranscriptView extends StatefulWidget {
  final TranscriptData transcript;
  final int highlightedIndex;
  final ScrollController? scrollController;
  final String? title;

  const TranscriptView({
    super.key,
    required this.transcript,
    required this.highlightedIndex,
    this.scrollController,
    this.title,
  });

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final GlobalKey _highlightKey = GlobalKey();

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
          if (widget.title != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.blue.shade200),
                ),
              ),
              child: Text(
                widget.title!,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade800,
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.transcript.segments.length,
              itemBuilder: (context, index) {
                final segment = widget.transcript.segments[index];
                final isHighlighted = index == widget.highlightedIndex;
                
                return Container(
                  key: isHighlighted ? _highlightKey : null,
                  child: _buildSegmentItem(segment, isHighlighted, index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentItem(SegmentData segment, bool isHighlighted, int index) {
    // Skip empty segments
    if (segment.text.isEmpty || segment.text.contains('<br')) {
      return const SizedBox.shrink();
    }

    // Check if this is a speaker change
    final isSpeakerChange = segment.speakerName != null && segment.speakerName!.isNotEmpty;

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
                      segment.speakerName!.replaceAll('Anonymous-', 'Unknown'),
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
