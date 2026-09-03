import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// What a playback engine has to be able to do.
///
/// The controller above it holds the rules — resume, track order, when a
/// position is written back — and nothing about a particular engine. That
/// keeps audio, video and, later, the readers on one controller, and it makes
/// the rules testable without a media stack underneath.
abstract interface class PlaybackEngine {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;

  /// Opens a file, starting at [start].
  ///
  /// The resume point belongs here rather than in a seek afterwards: a player
  /// that is told to seek before the file is loaded silently starts at zero,
  /// which is exactly how a saved position gets lost.
  Future<void> open(Uri uri, {Duration start = Duration.zero});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();

  /// The picture, for engines that have one. Null means audio only.
  Widget? videoSurface();
}

/// The real engine: libmpv through media_kit.
final class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine([Player? player]) : _player = player ?? Player() {
    // The video output has to exist before the first file is opened —
    // attaching it afterwards leaves the picture black while the sound plays.
    _video = VideoController(_player);
  }

  /// How long to wait for the file to report a length before checking that the
  /// resume point actually took.
  static const _readyTimeout = Duration(seconds: 3);

  final Player _player;
  late final VideoController _video;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    final resume = start > Duration.zero ? start : null;
    await _player.open(Media(uri.toString(), start: resume), play: false);
    if (resume == null) return;
    // mpv honours the start position while loading, but a container that
    // reports its length late can ignore it. So: wait for a length, then put
    // the position right if it did not take.
    try {
      await _player.stream.duration
          .firstWhere((value) => value > Duration.zero)
          .timeout(_readyTimeout);
    } on TimeoutException {
      // No length; the seek below is still worth a try.
    }
    if (_player.state.position < resume - const Duration(seconds: 2)) {
      await _player.seek(resume);
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Widget? videoSurface() =>
      Video(controller: _video, controls: NoVideoControls);

  @override
  Future<void> dispose() async => _player.dispose();
}
