import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'speech_engine.dart';

/// One continuous WAV stream for a chapter. Backpressure follows *heard*
/// sentences, not mpv read-ahead, so a long book never accumulates in memory.
final class SpeechAudioBuffer {
  SpeechAudioBuffer._(this._server, this._token);
  final HttpServer _server;
  final String _token;
  final _audio = StreamController<List<int>>();
  final _markers = Queue<({Duration end, SpeechTextSegment segment})>();
  final ready = Completer<void>();
  Completer<void>? _space;
  Duration _end = Duration.zero;
  bool _claimed = false;
  bool _closed = false;
  Object? failure;

  Uri get uri =>
      Uri.parse('http://127.0.0.1:${_server.port}/$_token/speech.wav');
  int get bufferedSentences => _markers.length;

  static Future<SpeechAudioBuffer> open() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final buffer = SpeechAudioBuffer._(
      server,
      List.generate(
        24,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
    server.listen(buffer._serve);
    return buffer;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path != uri.path ||
        !['GET', 'HEAD'].contains(request.method)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.headers.contentType = ContentType('audio', 'wav');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    if (_claimed || _closed) {
      response.statusCode = HttpStatus.gone;
      await response.close();
      return;
    }
    _claimed = true;
    try {
      response.add(_header());
      await response.addStream(_audio.stream);
      await response.close();
    } on Object {
      // The shared player closes the socket on Pause/Stop or a new reader run.
    }
  }

  Future<void> add(
    PhononAudio audio,
    SpeechTextSegment segment, {
    bool paragraphEnd = false,
  }) async {
    while (!_closed && _markers.length >= 4) {
      await (_space ??= Completer<void>()).future;
    }
    if (_closed) return;
    final pcm = speechPcm(
      audio.wav,
      pause: paragraphEnd
          ? const Duration(milliseconds: 300)
          : const Duration(milliseconds: 120),
    );
    _end += Duration(
      microseconds: pcm.length ~/ 2 * Duration.microsecondsPerSecond ~/ 24000,
    );
    _markers.add((end: _end, segment: segment));
    _audio.add(pcm);
    if (!ready.isCompleted &&
        (_markers.length >= 2 || _end >= const Duration(seconds: 8))) {
      ready.complete();
    }
  }

  List<SpeechTextSegment> heardUntil(Duration position) {
    final heard = <SpeechTextSegment>[];
    while (_markers.isNotEmpty && position >= _markers.first.end) {
      heard.add(_markers.removeFirst().segment);
    }
    if (heard.isNotEmpty) {
      final space = _space;
      _space = null;
      if (space != null && !space.isCompleted) space.complete();
    }
    return heard;
  }

  List<SpeechTextSegment> complete() => heardUntil(_end);

  void finish([Object? error]) {
    failure = error;
    if (!ready.isCompleted) ready.complete();
    if (!_closed) unawaited(_audio.close());
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    if (!ready.isCompleted) ready.complete();
    _space?.complete();
    _space = null;
    unawaited(_audio.close());
    await _server.close(force: true);
  }

  static Uint8List _header() {
    final wav = Uint8List(44);
    final data = ByteData.sublistView(wav);
    void ascii(int at, String text) =>
        wav.setRange(at, at + text.length, text.codeUnits);
    ascii(0, 'RIFF');
    data.setUint32(4, 0xffffffff, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 24000, Endian.little);
    data.setUint32(28, 48000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, 0xffffffff, Endian.little);
    return wav;
  }
}

/// Match Phonon's silence trimming while keeping 60 ms around speech and
/// gently fading edges. Never cut audible phonemes or rewrite original text.
Uint8List speechPcm(
  Uint8List wav, {
  Duration pause = const Duration(milliseconds: 120),
}) {
  if (wav.length < 46) throw const FormatException('Leeres Vorlese-Audio.');
  final samples = ByteData.sublistView(wav, 44);
  final count = samples.lengthInBytes ~/ 2;
  var first = 0;
  var last = count - 1;
  while (first < count &&
      samples.getInt16(first * 2, Endian.little).abs() <= 262) {
    first++;
  }
  while (last > first &&
      samples.getInt16(last * 2, Endian.little).abs() <= 262) {
    last--;
  }
  first = max(0, first - 1440);
  last = min(count - 1, last + 1440);
  if (first > last) {
    first = 0;
    last = min(count - 1, 1440);
  }
  final length = last - first + 1;
  final result = Uint8List(
    (length + pause.inMicroseconds * 24000 ~/ Duration.microsecondsPerSecond) *
        2,
  );
  final output = ByteData.sublistView(result);
  for (var index = 0; index < length; index++) {
    final fade = min(1.0, min(index / 192, (length - index - 1) / 600));
    output.setInt16(
      index * 2,
      (samples.getInt16((first + index) * 2, Endian.little) * fade).round(),
      Endian.little,
    );
  }
  return result;
}
