import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fundus_core/fundus_core.dart';

import '../data/work_view.dart';
import 'media_byte_source.dart';
import 'playback_engine.dart';

/// The one player.
///
/// Not one for local files and another for a server: the controller is handed
/// a [MediaByteSource] and does not know, or ask, where the bytes come from.
/// Streaming and offline copies join by adding an implementation of that
/// interface, not by growing a second controller.
class PlaybackController extends ChangeNotifier {
  PlaybackController({PlaybackEngine? engine, this.deviceId = 'device'})
    : _engineOrNull = engine;

  /// How often a position is written back. The design fixes this per media
  /// type — thirty seconds for audio and video, two minutes for text.
  static const _fallbackSaveInterval = Duration(seconds: 30);

  /// Built on first use. Creating the real engine spins up libmpv, and a
  /// library that is only browsed should not pay for that — nor should a
  /// widget test need it installed.
  PlaybackEngine? _engineOrNull;
  PlaybackEngine get _engine => _engineOrNull ??= MediaKitEngine();

  final String deviceId;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _saveTimer;

  FundusLibrary? _library;
  WorkView? _work;
  List<MediaByteSource> _sources = const [];
  List<LibraryPlaybackChapter> _chapters = const [];
  int _index = 0;

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  double _rate = 1;
  bool _expanded = false;
  String? _failure;

  WorkView? get work => _work;
  List<MediaByteSource> get sources => _sources;
  List<LibraryPlaybackChapter> get chapters => _chapters;
  int get trackIndex => _index;
  MediaByteSource? get currentSource =>
      _index < _sources.length ? _sources[_index] : null;

  Duration get position => _position;
  Duration? get duration => _duration;
  bool get isPlaying => _playing;
  double get rate => _rate;
  bool get hasWork => _work != null;

  /// Whether the full player covers the content column.
  bool get isExpanded => _expanded;
  String? get failure => _failure;

  /// True for the media types that carry a picture.
  bool get showsVideo => switch (_work?.mediaType?.id) {
    'movie' || 'series' || 'anime' => true,
    _ => false,
  };

  /// The video surface of the running engine, or null when there is nothing
  /// to show — no engine yet, or a media type without a picture.
  Widget? videoSurface() => showsVideo ? _engineOrNull?.videoSurface() : null;

  double get progressFraction {
    final total = _duration;
    if (total == null || total.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / total.inMilliseconds).clamp(0, 1);
  }

  /// Opens a work and starts at its stored position.
  Future<void> open(
    FundusLibrary library,
    WorkView work, {
    bool autoplay = true,
  }) async {
    _failure = null;
    _library = library;
    _work = work;
    // Starting a title opens the player; minimising is the deliberate step.
    _expanded = autoplay;

    try {
      final tracks = library.playbackTracks(work.id);
      if (tracks.isEmpty) {
        _failure = 'Zu diesem Werk sind keine abspielbaren Dateien erfasst.';
        notifyListeners();
        return;
      }
      _sources = [
        for (final track in tracks)
          LocalFileSource.fromTrack(track, origin: work.origin),
      ];
      _chapters = await library.playbackChapters(work.id);
      _attachStreams();

      final saved = library.loadProgress(work.id);
      final startIndex = saved?.fileId == null
          ? 0
          : _sources.indexWhere((s) => s.fileId == saved!.fileId);
      _index = startIndex < 0 ? 0 : startIndex;
      await _openCurrent(
        at: saved == null
            ? Duration.zero
            : Duration(
                milliseconds: ((saved.position.numericValue ?? 0) * 1000)
                    .round(),
              ),
      );
      if (autoplay) await _engine.play();
    } on Object catch (error) {
      _failure = error.toString();
    }
    notifyListeners();
  }

  Future<void> _openCurrent({Duration at = Duration.zero}) async {
    final source = currentSource;
    if (source == null) return;
    if (!await source.isReachable()) {
      // A file that is gone is a state, not a crash: the work keeps its
      // progress and the origin mark tells the story.
      _failure = 'Die Datei „${source.title}" ist nicht erreichbar.';
      notifyListeners();
      return;
    }
    final uri = await source.resolve();
    await _engine.open(uri, start: at);
    _duration = source.duration;
    _position = at;
    _startSaveTimer();
  }

  void _attachStreams() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.addAll([
      _engine.positionStream.listen((value) {
        _position = value;
        notifyListeners();
      }),
      _engine.durationStream.listen((value) {
        if (value > Duration.zero) _duration = value;
        notifyListeners();
      }),
      _engine.playingStream.listen((value) {
        _playing = value;
        if (!value) saveProgress();
        notifyListeners();
      }),
      _engine.completedStream.listen((value) {
        if (value) next();
      }),
    ]);
  }

  Future<void> playOrPause() async {
    if (_work == null || _engineOrNull == null) return;
    _playing ? await _engine.pause() : await _engine.play();
  }

  Future<void> seek(Duration value) async {
    await _engine.seek(value);
    _position = value;
    notifyListeners();
  }

  Future<void> seekRelative(Duration delta) => seek(
    _position + delta < Duration.zero ? Duration.zero : _position + delta,
  );

  Future<void> next() async {
    if (_index + 1 >= _sources.length) {
      await _engine.pause();
      _markFinished();
      return;
    }
    _index++;
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  Future<void> previous() async {
    // Like every player: back jumps to the start of the track first.
    if (_position > const Duration(seconds: 3) || _index == 0) {
      await seek(Duration.zero);
      return;
    }
    _index--;
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= _sources.length) return;
    _index = index;
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  Future<void> jumpToChapter(LibraryPlaybackChapter chapter) async {
    final index = _sources.indexWhere((s) => s.fileId == chapter.fileId);
    if (index >= 0 && index != _index) {
      _index = index;
      await _openCurrent(at: chapter.position);
      await _engine.play();
    } else {
      await seek(chapter.position);
    }
    notifyListeners();
  }

  Future<void> setRate(double value) async {
    _rate = value.clamp(0.5, 3);
    await _engine.setRate(_rate);
    notifyListeners();
  }

  Future<void> cycleRate() {
    const steps = [1.0, 1.25, 1.5, 1.75, 2.0, 0.75];
    final next = steps[(steps.indexOf(_rate) + 1) % steps.length];
    return setRate(next);
  }

  void expand() {
    _expanded = true;
    notifyListeners();
  }

  void collapse() {
    _expanded = false;
    notifyListeners();
  }

  Future<void> close() async {
    saveProgress();
    await _engineOrNull?.stop();
    _saveTimer?.cancel();
    _work = null;
    _sources = const [];
    _chapters = const [];
    _position = Duration.zero;
    _duration = null;
    _expanded = false;
    notifyListeners();
  }

  /// Writes the position back to the library.
  ///
  /// Metadata is never touched here: a position and a title are two different
  /// kinds of truth and must not share a transaction.
  void saveProgress({bool finished = false}) {
    final library = _library;
    final work = _work;
    final source = currentSource;
    if (library == null || work == null || source == null) return;
    if (library.isReadOnly) return;
    if (_position <= Duration.zero && !finished) return;
    try {
      library.saveProgress(
        workId: work.id,
        fileId: source.fileId,
        position: _position,
        duration: _duration,
        finished: finished,
        deviceId: deviceId,
      );
    } on Object {
      // Losing one autosave is not worth interrupting playback for; the next
      // tick writes again.
    }
  }

  void _markFinished() {
    saveProgress(finished: true);
    notifyListeners();
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    final interval =
        _work?.mediaType?.progressKind.saveInterval ?? _fallbackSaveInterval;
    _saveTimer = Timer.periodic(interval, (_) {
      if (_playing) saveProgress();
    });
  }

  @override
  void dispose() {
    saveProgress();
    _saveTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _engineOrNull?.dispose();
    super.dispose();
  }
}

/// Formats a duration the way the player shows it.
String formatPlaybackTime(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
