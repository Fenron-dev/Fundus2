import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// One selectable track of a file — a language, a commentary, a subtitle.
final class MediaTrackOption {
  const MediaTrackOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// What the file currently open offers, and what of it is playing.
///
/// A dual-audio anime is the ordinary case, not an exception: without this
/// the German track and the subtitles are simply out of reach.
final class MediaTracks {
  const MediaTracks({
    this.audio = const [],
    this.subtitles = const [],
    this.selectedAudioId,
    this.selectedSubtitleId,
  });

  final List<MediaTrackOption> audio;
  final List<MediaTrackOption> subtitles;
  final String? selectedAudioId;
  final String? selectedSubtitleId;

  /// Nothing to choose from is not worth a menu.
  bool get hasChoice => audio.length > 1 || subtitles.length > 1;
}

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

  /// The tracks of the file currently open, and the selection within it.
  Stream<MediaTracks> get tracksStream;

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

  Future<void> selectAudioTrack(String id);
  Future<void> selectSubtitleTrack(String id);

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
    _trackSubscriptions.addAll([
      _player.stream.tracks.listen((value) {
        _available = value;
        _emitTracks();
      }),
      _player.stream.track.listen((value) {
        _selected = value;
        _emitTracks();
      }),
    ]);
  }

  void _emitTracks() {
    if (_tracks.isClosed) return;
    _tracks.add(
      MediaTracks(
        audio: [
          for (final track in _available.audio)
            if (track.id != 'no')
              MediaTrackOption(
                id: track.id,
                label: _label(
                  id: track.id,
                  title: track.title,
                  language: track.language,
                  fallback: 'Ton',
                ),
              ),
        ],
        subtitles: [
          for (final track in _available.subtitle)
            MediaTrackOption(
              id: track.id,
              label: track.id == 'no'
                  ? 'Aus'
                  : _label(
                      id: track.id,
                      title: track.title,
                      language: track.language,
                      fallback: 'Untertitel',
                    ),
            ),
        ],
        selectedAudioId: _selected.audio.id,
        selectedSubtitleId: _selected.subtitle.id,
      ),
    );
  }

  /// What the file says about a track, in the order that helps: the title it
  /// carries, else its language, else a plain number.
  static String _label({
    required String id,
    required String? title,
    required String? language,
    required String fallback,
  }) {
    if (id == 'auto') return 'Automatisch';
    if (title != null && title.isNotEmpty && language != null) {
      return '$title ($language)';
    }
    if (title != null && title.isNotEmpty) return title;
    if (language != null && language.isNotEmpty) return language;
    return '$fallback $id';
  }

  /// How long to wait for the file to report a length before checking that the
  /// resume point actually took.
  static const _readyTimeout = Duration(seconds: 3);

  final Player _player;
  late final VideoController _video;

  /// mpv reports what is available and what is selected on two separate
  /// streams; the player only ever wants both together.
  final _tracks = StreamController<MediaTracks>.broadcast();
  final List<StreamSubscription<Object?>> _trackSubscriptions = [];
  Tracks _available = const Tracks();
  Track _selected = const Track();

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
  Stream<MediaTracks> get tracksStream => _tracks.stream;

  @override
  Future<void> selectAudioTrack(String id) async {
    final track = _available.audio.firstWhere(
      (candidate) => candidate.id == id,
      orElse: AudioTrack.auto,
    );
    await _player.setAudioTrack(track);
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    final track = _available.subtitle.firstWhere(
      (candidate) => candidate.id == id,
      orElse: SubtitleTrack.no,
    );
    await _player.setSubtitleTrack(track);
  }

  @override
  Widget? videoSurface() =>
      Video(controller: _video, controls: NoVideoControls);

  @override
  Future<void> dispose() async {
    for (final subscription in _trackSubscriptions) {
      await subscription.cancel();
    }
    await _tracks.close();
    await _player.dispose();
  }
}
