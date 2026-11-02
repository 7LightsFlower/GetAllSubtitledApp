// home_hub.dart
//
// Start page of the working screen: an overview of everything processed,
// with one card per list.
//
//            Your workspace
//   ┌──────────────────────────┐  ┌──────────────────────────┐
//   │ (🎞)  Videos           → │  │ (🎙)  Live sessions    → │
//   │ Uploaded videos with     │  │ Live transcription and   │
//   │ subtitles, translations… │  │ translation from the mic │
//   │ 12 videos · 3 folders    │  │ 8 sessions               │
//   │ ───────────────────────  │  │ ───────────────────────  │
//   │ ⬆ Upload a video         │  │ 🎙 New live session      │
//   └──────────────────────────┘  └──────────────────────────┘

import 'package:flutter/material.dart';

class HubEntry {
  const HubEntry({
    required this.icon,
    required this.title,
    required this.description,
    required this.stats,
    required this.accent,
    required this.onOpen,
    this.actionIcon,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;

  /// Short facts, e.g. ["12 videos", "3 folders"]. Empty while loading.
  final List<String> stats;
  final Color accent;
  final VoidCallback onOpen;

  /// Optional shortcut shown at the bottom of the card.
  final IconData? actionIcon;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class HomeHub extends StatelessWidget {
  const HomeHub({super.key, required this.entries, this.footer});

  final List<HubEntry> entries;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final cards = [for (final e in entries) _HubCard(entry: e)];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your workspace',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: narrow ? 20 : 24,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Open a list to work with your videos or live sessions.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.blueGrey.shade500),
            ),
            SizedBox(height: narrow ? 16 : 28),
            if (narrow)
              ...[
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 14),
                  cards[i],
                ],
              ]
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 20),
                      Expanded(child: cards[i]),
                    ],
                  ],
                ),
              ),
            if (footer != null) ...[
              const SizedBox(height: 24),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}

class _HubCard extends StatefulWidget {
  const _HubCard({required this.entry});
  final HubEntry entry;

  @override
  State<_HubCard> createState() => _HubCardState();
}

class _HubCardState extends State<_HubCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hover ? e.accent.withValues(alpha: 0.6) : Colors.grey.shade300,
            width: _hover ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _hover ? 0.10 : 0.04),
              blurRadius: _hover ? 18 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: e.onOpen,
            child: Padding(
              padding: EdgeInsets.all(narrow ? 16 : 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: narrow ? 46 : 54,
                        height: narrow ? 46 : 54,
                        decoration: BoxDecoration(
                          color: e.accent.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(e.icon,
                            color: e.accent, size: narrow ? 24 : 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          e.title,
                          style: TextStyle(
                            fontSize: narrow ? 18 : 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.blueGrey.shade900,
                          ),
                        ),
                      ),
                      AnimatedSlide(
                        duration: const Duration(milliseconds: 160),
                        offset: Offset(_hover ? 0.15 : 0, 0),
                        child: Icon(Icons.arrow_forward_rounded,
                            color: _hover ? e.accent : Colors.grey.shade500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    e.description,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: Colors.blueGrey.shade600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (e.stats.isEmpty)
                        _stat('…', e.accent)
                      else
                        for (final s in e.stats) _stat(s, e.accent),
                    ],
                  ),
                  if (e.actionLabel != null) ...[
                    // Side by side the cards share one height: push the
                    // shortcut to the bottom. Stacked (phones) the height
                    // is unbounded, so no Spacer there.
                    if (!narrow) const Spacer(),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: Colors.grey.shade200),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: e.onAction,
                      icon: Icon(e.actionIcon ?? Icons.add, size: 18),
                      label: Text(e.actionLabel!),
                      style: TextButton.styleFrom(
                        foregroundColor: e.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String text, Color accent) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: accent,
          ),
        ),
      );
}
