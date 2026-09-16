// lib/models/job_progress.dart
class JobEvent {
  final String time;
  final String level;
  final String message;

  const JobEvent({
    required this.time,
    required this.level,
    required this.message,
  });

  factory JobEvent.fromJson(Map<String, dynamic> json) => JobEvent(
        time: json['time'] as String? ?? '',
        level: json['level'] as String? ?? 'info',
        message: json['message'] as String? ?? '',
      );
}

class JobFileInfo {
  final String name;
  final int size;

  const JobFileInfo({required this.name, required this.size});

  factory JobFileInfo.fromJson(Map<String, dynamic> json) => JobFileInfo(
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

class JobProgress {
  final String sessionId;
  final String stage;
  final double progress;
  final String message;
  final List<JobEvent> events;
  final List<JobFileInfo> files;
  final bool done;
  final String? error;

  const JobProgress({
    required this.sessionId,
    required this.stage,
    required this.progress,
    required this.message,
    required this.events,
    required this.files,
    required this.done,
    required this.error,
  });

  factory JobProgress.fromJson(Map<String, dynamic> json) => JobProgress(
        sessionId: json['session_id'] as String? ?? '',
        stage: json['stage'] as String? ?? 'unknown',
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        message: json['message'] as String? ?? '',
        events: (json['events'] as List?)
                ?.map((e) => JobEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        files: (json['files'] as List?)
                ?.map((e) => JobFileInfo.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        done: json['done'] as bool? ?? false,
        error: json['error'] as String?,
      );

  static const empty = JobProgress(
    sessionId: '',
    stage: 'starting',
    progress: 0.0,
    message: 'Waiting for server…',
    events: [],
    files: [],
    done: false,
    error: null,
  );
}