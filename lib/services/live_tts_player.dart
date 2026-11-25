// live_tts_player.dart
//
// Plays KIT's spoken translation (TTS) live, chunk by chunk, as the relay
// forwards it. Chunks are decoded in arrival order and scheduled back to
// back on one AudioContext, so speech never overlaps or reorders.
//
// Formats: anything the browser can decode (WAV, MP3, Ogg/Opus, WebM) via
// decodeAudioData, plus raw 16-bit PCM when the field name says so
// (e.g. "b64_enc_pcm_s16le") with the sample rate KIT reports.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

class LiveTtsPlayer {
  web.AudioContext? _ctx;
  double _nextStart = 0;
  Future<void> _chain = Future.value();

  /// Create/resume the AudioContext. Call from a user gesture (a tap),
  /// otherwise the browser keeps it muted.
  Future<void> unlock() async {
    final ctx = _ctx ??= web.AudioContext();
    if (ctx.state == 'suspended') {
      try {
        await ctx.resume().toDart;
      } catch (_) {}
    }
  }

  final List<Timer> _timers = <Timer>[];

  /// Queue one chunk. Returns immediately; playback is serialized.
  /// [onStart] / [onEnd] fire when this chunk is actually heard (it may
  /// wait behind earlier chunks).
  void enqueue(String base64Audio,
      {String? format, int? rate, VoidCallback? onStart, VoidCallback? onEnd}) {
    _chain = _chain
        .then((_) => _play(base64Audio, format, rate, onStart, onEnd))
        .catchError(
          (Object e) => debugPrint('live TTS chunk skipped: $e'),
        );
  }

  Future<void> _play(String b64, String? format, int? rate,
      VoidCallback? onStart, VoidCallback? onEnd) async {
    final ctx = _ctx;
    if (ctx == null) return; // stopped
    final bytes = Uint8List.fromList(base64Decode(b64));
    if (bytes.isEmpty) return;

    final isWav = bytes.length > 4 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;
    final fmt = (format ?? '').toLowerCase();

    final web.AudioBuffer buffer;
    if (!isWav && (fmt.contains('pcm') || fmt.contains('s16'))) {
      final n = bytes.length ~/ 2;
      final data = ByteData.sublistView(bytes);
      final samples = Float32List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
      }
      buffer = ctx.createBuffer(1, n, rate ?? 16000);
      buffer.copyToChannel(samples.toJS, 0);
    } else {
      buffer = await ctx.decodeAudioData(bytes.buffer.toJS).toDart;
    }
    if (_ctx != ctx) return; // stopped while decoding

    final source = ctx.createBufferSource()..buffer = buffer;
    source.connect(ctx.destination);
    final now = ctx.currentTime;
    // Small lead-in when the queue ran dry, otherwise play right after
    // the previous chunk.
    if (_nextStart < now) _nextStart = now + 0.05;
    source.start(_nextStart);
    final startsIn = Duration(milliseconds: ((_nextStart - now) * 1000).round());
    final endsIn = startsIn +
        Duration(milliseconds: (buffer.duration * 1000).round());
    if (onStart != null) _timers.add(Timer(startsIn, onStart));
    if (onEnd != null) _timers.add(Timer(endsIn, onEnd));
    _timers.removeWhere((t) => !t.isActive);
    _nextStart += buffer.duration;
  }

  /// Stop immediately and drop everything queued.
  Future<void> stop() async {
    final ctx = _ctx;
    _ctx = null;
    _nextStart = 0;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _chain = Future.value();
    if (ctx != null) {
      try {
        await ctx.close().toDart;
      } catch (_) {}
    }
  }
}
