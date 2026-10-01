// models/tts_track.dart
class TTSTrack {
  final String label;      // "English Audio", "German Audio", ...
  final String url;        // /session-tts/<id>/English Audio
  final String language;   // resolved display name, e.g. "English"

  const TTSTrack({
    required this.label,
    required this.url,
    required this.language,
  });
}