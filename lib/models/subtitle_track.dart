// lib/models/subtitle_track.dart
class SubtitleTrack {
  final String language;
  final String label;
  final String url;
  final String? content; // For in-memory subtitles

  const SubtitleTrack({
    required this.language,
    required this.label,
    required this.url,
    this.content,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SubtitleTrack &&
        other.language == language &&
        other.label == label &&
        other.url == url &&
        other.content == content;
  }

  @override
  int get hashCode => Object.hash(language, label, url, content);
}