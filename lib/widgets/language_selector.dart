// language_selector.dart
// Compact replacement for LanguageTabs — keeps the header small even when a
// session has dozens of translations.

import 'package:flutter/material.dart';
import 'package:asr_live_translator/models/session_data.dart';
import 'package:asr_live_translator/constants.dart';

class LanguageSelector extends StatelessWidget {
  final List<TranscriptData> transcripts;
  final String selectedLanguage;
  final ValueChanged<String> onLanguageSelected;
  final bool enabled;

  const LanguageSelector({
    super.key,
    required this.transcripts,
    required this.selectedLanguage,
    required this.onLanguageSelected,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = selectedLanguage.isEmpty
        ? 'Select language'
        : resolveLanguageName(selectedLanguage);
    final category = _categoryOf(selectedLanguage);

    return Material(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: enabled && transcripts.isNotEmpty
            ? () => _openPicker(context)
            : null,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconForCategory(category),
                  size: 18, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    display,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${transcripts.length}',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more,
                  size: 18, color: theme.colorScheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _LanguagePickerDialog(
        transcripts: transcripts,
        selectedLanguage: selectedLanguage,
      ),
    );
    if (selected != null && selected != selectedLanguage) {
      onLanguageSelected(selected);
    }
  }

  static String _categoryOf(String language) {
    final l = language.toLowerCase();
    if (l.contains('original') ||
        l.contains('asr') ||
        l.contains('transcript')) {
      return 'Transcripts';
    }
    if (l.contains('structured')) return 'Structured';
    if (l.contains('translation')) return 'Translations';
    return 'Other';
  }

  static IconData _iconForCategory(String category) {
    switch (category) {
      case 'Transcripts':
        return Icons.record_voice_over;
      case 'Translations':
        return Icons.translate;
      case 'Structured':
        return Icons.article;
      default:
        return Icons.language;
    }
  }
}

// ─── Dialog ────────────────────────────────────────────────────────────

class _LanguagePickerDialog extends StatefulWidget {
  final List<TranscriptData> transcripts;
  final String selectedLanguage;

  const _LanguagePickerDialog({
    required this.transcripts,
    required this.selectedLanguage,
  });

  @override
  State<_LanguagePickerDialog> createState() => _LanguagePickerDialogState();
}

class _LanguagePickerDialogState extends State<_LanguagePickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.transcripts.where((t) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return t.language.toLowerCase().contains(q) ||
          resolveLanguageName(t.language).toLowerCase().contains(q);
    }).toList();

    final Map<String, List<TranscriptData>> grouped = {};
    for (final t in filtered) {
      grouped
          .putIfAbsent(LanguageSelector._categoryOf(t.language), () => [])
          .add(t);
    }

    const order = ['Transcripts', 'Translations', 'Structured', 'Other'];
    final orderedCats = order.where(grouped.containsKey).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.language, color: Colors.blue, size: 22),
                  const SizedBox(width: 10),
                  const Text(
                    'Select language',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search ${widget.transcripts.length} languages…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            // List
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(40),
                      child: Text('No matching languages'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (final cat in orderedCats) ...[
                          _SectionHeader(
                            label: cat,
                            icon: LanguageSelector._iconForCategory(cat),
                            count: grouped[cat]!.length,
                          ),
                          for (final t in grouped[cat]!)
                            _LanguageTile(
                              language: t.language,
                              isSelected:
                                  t.language == widget.selectedLanguage,
                              segmentCount: t.segments.length,
                              onTap: () => Navigator.pop(context, t.language),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;

  const _SectionHeader({
    required this.label,
    required this.icon,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(width: 8),
          Text('($count)',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: Colors.grey.shade300)),
        ],
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  final String language;
  final bool isSelected;
  final int segmentCount;
  final VoidCallback onTap;

  const _LanguageTile({
    required this.language,
    required this.isSelected,
    required this.segmentCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = resolveLanguageName(language);
    // Show the raw label as a subtitle only when it adds information,
    // e.g. "Translation (German)" vs "German".
    final showRaw = language != display &&
        !display.toLowerCase().contains(language.toLowerCase()) &&
        !language.toLowerCase().contains('original asr') &&
        !language.toLowerCase().startsWith('transcript');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: isSelected
                      ? Icon(Icons.check_circle,
                          size: 18, color: theme.colorScheme.primary)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        display.isEmpty ? language : display,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (showRaw)
                        Text(
                          language,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$segmentCount',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}