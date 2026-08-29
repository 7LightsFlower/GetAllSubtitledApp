// models/session_data.dart

class TranscriptData {
  final String language;
  final String text;
  final List<SegmentData> segments;
  final String sender;

  const TranscriptData({
    required this.language,
    required this.text,
    required this.segments,
    required this.sender,
  });

  factory TranscriptData.fromJson(Map<String, dynamic> json) {
    final segmentsList = json['segments'] as List? ?? [];
    return TranscriptData(
      language: json['language'] ?? 'Unknown',
      text: json['text'] ?? '',
      sender: json['sender'] ?? '',
      segments: segmentsList.map((s) => SegmentData.fromJson(s)).toList(),
    );
  }

  factory TranscriptData.empty() {
    return const TranscriptData(
      language: 'Unknown',
      text: '',
      segments: [],
      sender: '',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TranscriptData &&
        other.language == language &&
        other.text == text &&
        other.segments == segments &&
        other.sender == sender;
  }

  @override
  int get hashCode => Object.hash(language, text, segments, sender);
}

class SegmentData {
  final String text;
  final double start;
  final double end;
  final String sender;
  final String? markup;
  final List<String>? words;
  final List<int>? wordId;
  final List<int>? sourceTokens;
  final String? speakerName;
  final String? refinedSentenceCluster;
  final bool unstable;
  final int? messageId;

  const SegmentData({
    required this.text,
    required this.start,
    required this.end,
    required this.sender,
    this.markup,
    this.words,
    this.wordId,
    this.sourceTokens,
    this.speakerName,
    this.refinedSentenceCluster,
    this.unstable = false,
    this.messageId,
  });

  factory SegmentData.fromJson(Map<String, dynamic> json) {
    return SegmentData(
      text: json['text'] ?? '',
      start: (json['start'] ?? 0).toDouble(),
      end: (json['end'] ?? 0).toDouble(),
      sender: json['sender'] ?? '',
      markup: json['markup'],
      words: json['words'] != null ? List<String>.from(json['words']) : null,
      wordId: json['word_id'] != null ? List<int>.from(json['word_id']) : null,
      sourceTokens: json['source_tokens'] != null ? List<int>.from(json['source_tokens']) : null,
      speakerName: json['speaker_name'],
      refinedSentenceCluster: json['refined_sentence_cluster'],
      unstable: json['unstable'] ?? false,
      messageId: json['message_id'],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SegmentData &&
        other.text == text &&
        other.start == start &&
        other.end == end &&
        other.sender == sender;
  }

  @override
  int get hashCode => Object.hash(text, start, end, sender);
}

class ChapterData {
  final double start;
  final double end;
  final int index;
  final String heading;
  final List<SegmentData> segments;

  const ChapterData({
    required this.start,
    required this.end,
    required this.index,
    required this.heading,
    this.segments = const [],
  });

  ChapterData copyWith({
    double? start,
    double? end,
    int? index,
    String? heading,
    List<SegmentData>? segments,
  }) {
    return ChapterData(
      start: start ?? this.start,
      end: end ?? this.end,
      index: index ?? this.index,
      heading: heading ?? this.heading,
      segments: segments ?? this.segments,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChapterData &&
        other.start == start &&
        other.end == end &&
        other.index == index &&
        other.heading == heading &&
        other.segments == segments;
  }

  @override
  int get hashCode => Object.hash(start, end, index, heading, segments);
}

class SessionFile {
  final String name;
  final int size;
  final String url;

  const SessionFile({
    required this.name,
    required this.size,
    required this.url,
  });

  factory SessionFile.fromJson(Map<String, dynamic> json) {
    return SessionFile(
      name: json['name'] ?? '',
      size: json['size'] ?? 0,
      url: json['url'] ?? '',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionFile &&
        other.name == name &&
        other.size == size &&
        other.url == url;
  }

  @override
  int get hashCode => Object.hash(name, size, url);
}
