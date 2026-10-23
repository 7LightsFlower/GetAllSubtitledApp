// browser_microphone.dart
//
// Captures the browser's own microphone and emits raw PCM chunks in
// the format the KIT ASR expects: signed 16-bit little-endian, mono,
// 16 kHz ("pcm_s16le").
//
// Uses a ScriptProcessorNode. It is deprecated in favour of
// AudioWorklet but works in every current browser without shipping a
// separate worklet JS file, which keeps this a single Dart file.
//
// The AudioContext runs at the device rate (usually 44.1 / 48 kHz):
// Firefox refuses to connect a mic stream to a context with a
// different rate, so we downsample here instead of asking the context
// for 16 kHz.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class BrowserMicrophone {
  BrowserMicrophone({this.chunkDuration = const Duration(milliseconds: 250)});

  static const int targetSampleRate = 16000;

  /// How much audio each emitted chunk holds.
  final Duration chunkDuration;

  final _chunks = StreamController<Uint8List>.broadcast();
  final _levels = StreamController<double>.broadcast();

  /// PCM s16le mono 16 kHz, one event per [chunkDuration].
  Stream<Uint8List> get chunks => _chunks.stream;

  /// Input level 0…1 (RMS, scaled), for a VU meter.
  Stream<double> get levels => _levels.stream;

  bool get isRunning => _ctx != null;

  web.MediaStream? _stream;
  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _source;
  web.ScriptProcessorNode? _processor;
  web.GainNode? _silent;

  // Resampler state carried across audio callbacks.
  Float32List _carry = Float32List(0);
  double _pos = 0;

  // Output accumulator.
  final BytesBuilder _out = BytesBuilder(copy: false);
  int get _chunkBytes =>
      targetSampleRate * 2 * chunkDuration.inMilliseconds ~/ 1000;

  /// Asks for mic permission and starts capturing. Throws a readable
  /// [MicrophoneException] if the browser refuses.
  Future<void> start() async {
    if (isRunning) return;

    final devices = web.window.navigator.mediaDevices;
    try {
      _stream = await devices
          .getUserMedia(
            web.MediaStreamConstraints(
              audio: <String, Object>{
                'channelCount': 1,
                'echoCancellation': true,
                'noiseSuppression': true,
                'autoGainControl': true,
              }.jsify()!,
            ),
          )
          .toDart;
    } catch (e) {
      throw MicrophoneException.fromBrowserError(e);
    }

    final ctx = web.AudioContext();
    _ctx = ctx;
    _source = ctx.createMediaStreamSource(_stream!);
    _processor = ctx.createScriptProcessor(4096, 1, 1);
    // ScriptProcessor only fires while connected to the destination;
    // route it through a muted gain so the user doesn't hear themselves.
    _silent = ctx.createGain()..gain.value = 0;

    _processor!.onaudioprocess = ((web.AudioProcessingEvent e) {
      _onAudio(e.inputBuffer.getChannelData(0).toDart);
    }).toJS;

    _source!.connect(_processor!);
    _processor!.connect(_silent!);
    _silent!.connect(ctx.destination);

    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
  }

  /// Stops capturing, releases the mic (the browser's red dot goes
  /// away) and flushes whatever audio is still buffered.
  Future<void> stop() async {
    if (!isRunning) return;
    _processor?.onaudioprocess = null;
    try {
      _source?.disconnect();
      _processor?.disconnect();
      _silent?.disconnect();
    } catch (_) {}
    final tracks = _stream?.getTracks().toDart ?? const <web.MediaStreamTrack>[];
    for (final t in tracks) {
      t.stop();
    }
    try {
      await _ctx?.close().toDart;
    } catch (_) {}
    _ctx = null;
    _stream = null;
    _source = null;
    _processor = null;
    _silent = null;
    _carry = Float32List(0);
    _pos = 0;

    if (_out.length > 0) _chunks.add(_out.takeBytes());
    _levels.add(0);
  }

  Future<void> dispose() async {
    await stop();
    await _chunks.close();
    await _levels.close();
  }

  // ── audio callback ────────────────────────────────────────────────
  void _onAudio(Float32List input) {
    // Level meter.
    var sum = 0.0;
    for (final v in input) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / math.max(1, input.length));
    _levels.add(math.min(1.0, rms * 4));

    // Downsample with a box filter: each output sample is the mean of
    // the input samples it covers. Cheap, and averages away most of
    // the content above 8 kHz that would otherwise alias.
    final ratio = _ctx!.sampleRate / targetSampleRate;
    final buf = Float32List(_carry.length + input.length)
      ..setAll(0, _carry)
      ..setAll(_carry.length, input);

    final outSamples = <int>[];
    var pos = _pos;
    while (pos + ratio <= buf.length) {
      final a = pos.floor();
      final b = math.max(a + 1, (pos + ratio).floor());
      var acc = 0.0;
      for (var i = a; i < b; i++) {
        acc += buf[i];
      }
      final s = (acc / (b - a)).clamp(-1.0, 1.0);
      outSamples.add((s * 32767).round());
      pos += ratio;
    }
    final keepFrom = pos.floor();
    _carry = Float32List.sublistView(buf, keepFrom);
    _pos = pos - keepFrom;

    if (outSamples.isEmpty) return;
    final bytes = ByteData(outSamples.length * 2);
    for (var i = 0; i < outSamples.length; i++) {
      bytes.setInt16(i * 2, outSamples[i], Endian.little);
    }
    _out.add(bytes.buffer.asUint8List());

    while (_out.length >= _chunkBytes) {
      final all = _out.takeBytes();
      _chunks.add(Uint8List.sublistView(all, 0, _chunkBytes));
      if (all.length > _chunkBytes) {
        _out.add(Uint8List.sublistView(all, _chunkBytes));
      }
    }
  }
}

class MicrophoneException implements Exception {
  MicrophoneException(this.message);
  final String message;

  factory MicrophoneException.fromBrowserError(Object e) {
    final s = e.toString();
    if (s.contains('NotAllowed') || s.contains('Permission')) {
      return MicrophoneException(
        'Microphone access was blocked. Allow it in the browser’s address '
        'bar (site settings) and try again.',
      );
    }
    if (s.contains('NotFound') || s.contains('DevicesNotFound')) {
      return MicrophoneException('No microphone was found on this device.');
    }
    if (s.contains('NotReadable') || s.contains('TrackStart')) {
      return MicrophoneException(
        'The microphone is in use by another application.',
      );
    }
    if (s.contains('Security') || s.contains('secure')) {
      return MicrophoneException(
        'The browser only allows the microphone on https:// or localhost.',
      );
    }
    return MicrophoneException('Could not start the microphone: $s');
  }

  @override
  String toString() => message;
}
