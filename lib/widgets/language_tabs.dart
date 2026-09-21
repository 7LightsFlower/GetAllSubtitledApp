// widgets/language_tabs.dart
import 'package:flutter/material.dart';
import 'package:asr_live_translator/models/session_data.dart';
import 'package:asr_live_translator/constants.dart';

class LanguageTabs extends StatelessWidget {
  final List<TranscriptData> transcripts;
  final String selectedLanguage;
  final Function(String) onLanguageSelected;

  const LanguageTabs({
    super.key,
    required this.transcripts,
    required this.selectedLanguage,
    required this.onLanguageSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (transcripts.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: transcripts.map((transcript) {
            final isSelected = transcript.language == selectedLanguage;
            
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _buildLanguageChip(transcript, isSelected),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildLanguageChip(TranscriptData transcript, bool isSelected) {
    return GestureDetector(
      onTap: () => onLanguageSelected(transcript.language),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade700 : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? Colors.blue.shade700 : Colors.grey.shade400,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getLanguageLabel(transcript.language),
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade700,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
            if (transcript.segments.isNotEmpty) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white24 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${transcript.segments.length}',
                  style: TextStyle(
                    fontSize: 9,
                    color: isSelected ? Colors.white : Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getLanguageLabel(String language) {
    if (language.isEmpty) return 'Unknown';

    final lower = language.toLowerCase();

    // Speaker's own track (Original ASR) → just "Transcript"
    if (lower.contains('original') || lower.contains('asr')) {
      return 'Transcript';
    }

    // Everything else → plain language name
    // "Translation (Language Arabic)" → "Arabic"
    // "Translation (Language de)"     → "German"
    // "Structured (English)"          → "English"
    // "English"                       → "English"
    return resolveLanguageName(language);
  }
}
