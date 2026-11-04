import 'dart:async';

import 'package:fundus_core/fundus_core.dart';

import '../data/work_view.dart';
import 'playback_controller.dart';
import 'reader_controller.dart';
import 'text_reader_controller.dart';

/// Counts the time spent with a work and writes it down as play events.
///
/// Playback counts while the player plays. Reading counts while a reader is
/// open and something happens in it; a pause of more than five minutes
/// between two page turns is left out, because a book left open overnight is
/// not eight hours of reading. While a work is being read aloud the player
/// already counts it, so the reader does not count it a second time.
///
/// Nothing here leaves the device: the events stay in the local index.
final class UsageRecorder {
  UsageRecorder({
    required this.player,
    required this.reader,
    required this.textReader,
    required this.library,
    required this.deviceId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackController player;
  final ReaderController reader;
  final TextReaderController textReader;
  final FundusLibrary? Function() library;
  final String deviceId;
  final DateTime Function() _clock;

  /// Shorter stretches are noise: a work opened by mistake, a skim.
  static const minimumSeconds = 30;
  static const readingGap = Duration(minutes: 5);
  static const _flushEvery = Duration(minutes: 5);

  Timer? _flushTimer;
  final _playback = _Stretch();
  final _comic = _Stretch();
  final _text = _Stretch();
  DateTime? _playingSince;

  void attach() {
    player.addListener(_playerChanged);
    reader.addListener(_readerChanged);
    textReader.addListener(_textReaderChanged);
    _flushTimer = Timer.periodic(_flushEvery, (_) => flush(partial: true));
    _playerChanged();
  }

  void detach() {
    player.removeListener(_playerChanged);
    reader.removeListener(_readerChanged);
    textReader.removeListener(_textReaderChanged);
    _flushTimer?.cancel();
    _flushTimer = null;
    flush();
  }

  void _playerChanged() {
    final now = _clock();
    final workId = player.work?.id;
    if (workId != _playback.workId) {
      _stopPlaying(now);
      _write(_playback);
      _playback.reset(workId);
    }
    if (player.isPlaying && workId != null) {
      _playingSince ??= now;
      _playback.startedAt ??= now;
    } else {
      _stopPlaying(now);
    }
  }

  void _stopPlaying(DateTime now) {
    final since = _playingSince;
    if (since == null) return;
    _playback.seconds += now.difference(since).inSeconds;
    _playback.endedAt = now;
    _playingSince = null;
  }

  void _readerChanged() =>
      _readingActivity(_comic, reader.isOpen ? reader.work : null);

  void _textReaderChanged() =>
      _readingActivity(_text, textReader.isOpen ? textReader.work : null);

  void _readingActivity(_Stretch stretch, WorkView? work) {
    final now = _clock();
    final workId = work?.id;
    if (workId != stretch.workId) {
      _write(stretch);
      stretch.reset(workId);
    }
    if (workId == null) return;
    // Read aloud: the player is already counting this.
    if (player.isPlaying && player.work?.id == workId) {
      stretch.lastActivity = null;
      return;
    }
    final last = stretch.lastActivity;
    if (last != null) {
      final gap = now.difference(last);
      if (gap <= readingGap) stretch.seconds += gap.inSeconds;
    }
    stretch.startedAt ??= now;
    stretch.endedAt = now;
    stretch.lastActivity = now;
  }

  /// Writes what has been counted so far. With [partial] a running stretch
  /// goes on afterwards; it only no longer risks being lost with the app.
  void flush({bool partial = false}) {
    final now = _clock();
    final playing = _playingSince != null;
    _stopPlaying(now);
    _write(_playback);
    _write(_comic);
    _write(_text);
    if (partial && playing) {
      _playingSince = now;
      _playback.startedAt = now;
    }
  }

  void _write(_Stretch stretch) {
    final workId = stretch.workId;
    final started = stretch.startedAt;
    final ended = stretch.endedAt;
    final seconds = stretch.seconds;
    stretch.clear();
    final vault = library();
    if (workId == null ||
        started == null ||
        ended == null ||
        seconds < minimumSeconds ||
        vault == null) {
      return;
    }
    try {
      vault.recordPlayEvent(
        workId: workId,
        startedAt: started,
        endedAt: ended,
        secondsPlayed: seconds,
        deviceId: deviceId,
      );
    } on Object {
      // Statistics are worth less than whatever was happening.
    }
  }
}

final class _Stretch {
  String? workId;
  DateTime? startedAt;
  DateTime? endedAt;
  DateTime? lastActivity;
  int seconds = 0;

  void reset(String? work) {
    clear();
    lastActivity = null;
    workId = work;
  }

  /// Keeps the work and the last sign of life, forgets the counted time.
  void clear() {
    startedAt = null;
    endedAt = null;
    seconds = 0;
  }
}
