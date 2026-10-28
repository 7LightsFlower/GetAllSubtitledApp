// view_switcher.dart
//
// Pill-shaped two-way switch, centred on the page:
//
//      ╭──────────────────────────────────────────╮
//      │ ███ 🎞 Video list ███    🎙 Live transcripts │
//      ╰──────────────────────────────────────────╯
//
// The selected side is a filled, raised pill that slides across.

import 'package:flutter/material.dart';

class ViewSwitcherOption {
  const ViewSwitcherOption({
    required this.icon,
    required this.label,
    this.shortLabel,
  });
  final IconData icon;
  final String label;
  final String? shortLabel; // used on phones
}

class ViewSwitcher extends StatelessWidget {
  const ViewSwitcher({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<ViewSwitcherOption> options;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final accent = Colors.blue.shade700;

    return Center(
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++)
              _segment(options[i], i == selected, narrow, accent, () {
                if (i != selected) onChanged(i);
              }),
          ],
        ),
      ),
    );
  }

  Widget _segment(ViewSwitcherOption o, bool active, bool narrow, Color accent,
      VoidCallback onTap) {
    final fg = active ? Colors.white : Colors.blueGrey.shade700;
    return Semantics(
      selected: active,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: active ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(26),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(26),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: narrow ? 16 : 26,
                vertical: narrow ? 9 : 11,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(o.icon, size: narrow ? 18 : 20, color: fg),
                  const SizedBox(width: 8),
                  Text(
                    narrow ? (o.shortLabel ?? o.label) : o.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: narrow ? 14 : 15,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
