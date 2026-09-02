import 'dart:async';

import 'package:media_kit/media_kit.dart';

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

  Future<void> open(Uri uri);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();
}

/// The real engine: libmpv through media_kit.
final class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine([Player? player]) : _player = player ?? Player();

  final Player _player;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Future<void> open(Uri uri) =>
      _player.open(Media(uri.toString()), play: false);

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
  Future<void> dispose() async => _player.dispose();
}
