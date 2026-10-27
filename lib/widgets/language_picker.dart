// language_picker.dart
//
// Language selection used in the video Session Detail and the Live Session
// settings. Only the chosen languages are always visible; all others sit
// in a collapsed "Add languages" list (with search), in every UI mode.

import 'package:flutter/material.dart';

class LanguagePicker extends StatefulWidget {
  const LanguagePicker({
    super.key,
    required this.title,
    required this.availableCodes,
    required this.selected,
    required this.nameFor,
    required this.onToggle,
    required this.onReplaceAll,
    this.titleSize,
  });

  final String title;
  final List<String> availableCodes;
  final List<String> selected;
  final String Function(String code) nameFor;
  final void Function(String code) onToggle;
  final void Function(List<String> codes) onReplaceAll;
  final double? titleSize;

  @override
  State<LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<LanguagePicker> {
  bool _expanded = false;
  String _query = '';

  bool _narrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;

  Widget _chip(String code, bool selected) {
    final narrow = _narrow(context);
    return FilterChip(
      label: Text(
        '${widget.nameFor(code)} ($code)',
        style: TextStyle(fontSize: narrow ? 11 : 13),
      ),
      selected: selected,
      onSelected: (_) => widget.onToggle(code),
      visualDensity: narrow ? VisualDensity.compact : VisualDensity.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = _narrow(context);
    final chosen =
        widget.availableCodes.where(widget.selected.contains).toList();
    final others =
        widget.availableCodes.where((c) => !widget.selected.contains(c)).toList();
    final q = _query.trim().toLowerCase();
    final shownOthers = q.isEmpty
        ? others
        : others
            .where((c) =>
                c.toLowerCase().contains(q) ||
                widget.nameFor(c).toLowerCase().contains(q))
            .toList();

    Widget action(String label, VoidCallback? onPressed) => TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 6 : 8),
            minimumSize: Size(0, narrow ? 28 : 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: TextStyle(fontSize: narrow ? 12 : 13),
          ),
          child: Text(label),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Title + All / None ──
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: widget.titleSize ?? (narrow ? 13 : 14),
                ),
              ),
            ),
            action(
              'All',
              others.isEmpty
                  ? null
                  : () => widget.onReplaceAll([...widget.availableCodes]),
            ),
            const SizedBox(width: 2),
            action('None',
                chosen.isEmpty ? null : () => widget.onReplaceAll(const [])),
          ],
        ),
        const SizedBox(height: 4),

        // ── Chosen languages (always visible) ──
        if (chosen.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'None selected',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Colors.grey.shade600,
              ),
            ),
          )
        else
          Wrap(
            spacing: narrow ? 6 : 8,
            runSpacing: 4,
            children: [for (final c in chosen) _chip(c, true)],
          ),

        // ── Unchosen languages (collapsed) ──
        if (others.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _expanded = !_expanded;
                if (!_expanded) _query = '';
              }),
              icon: Icon(_expanded ? Icons.expand_less : Icons.add, size: 18),
              label: Text(
                _expanded
                    ? 'Hide other languages'
                    : 'Add languages (${others.length})',
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topLeft,
          child: !_expanded || others.isEmpty
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (others.length > 8) ...[
                        TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search languages…',
                            prefixIcon: Icon(Icons.search, size: 18),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (shownOthers.isEmpty)
                        Text(
                          'No language matches "$_query".',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        )
                      else
                        Wrap(
                          spacing: narrow ? 6 : 8,
                          runSpacing: 4,
                          children: [for (final c in shownOthers) _chip(c, false)],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
