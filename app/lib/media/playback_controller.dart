import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';

import '../data/work_view.dart';
import 'media_byte_source.dart';
import 'playback_engine.dart';
import 'playback_preference.dart';
import 'track_preference.dart';

/// The one player.
///
/// Not one for local files and another for a server: the controller is handed
/// a [MediaByteSource] and does not know, or ask, where the bytes come from.
/// Streaming and offline copies join by adding an implementation of that
/// interface, not by growing a second controller.
class PlaybackController extends ChangeNotifier {
  PlaybackController({PlaybackEngine? engine, this.deviceId = 'device'})
    : _engineOrNull = engine;

  /// How this device plays — speed, skip distances, the sleep timer. Kept by
  /// the scope in the vault's device profile.
  PlaybackPreference habits = const PlaybackPreference();
  Future<void> Function(PlaybackPreference value)? onHabitsChanged;

  Timer? _sleepTimer;
  Timer? _sleepTick;
  DateTime? _sleepEndsAt;
  bool _sleepingAtChapterEnd = false;

  /// The languages this device watches in, and the way to store a change.
  ///
  /// Kept by the scope in the vault's device profile rather than here: it is
  /// a setting that must survive a reinstall, and the vault is what survives.
  TrackPreference preference = const TrackPreference();
  Future<void> Function(TrackPreference value)? onPreferenceChanged;

  /// Set once per opened file — mpv reports its tracks more than once.
  bool _appliedPreference = false;

  /// Where remote bytes come from while a paired library is open.
  ///
  /// Set by the scope when a peer library opens and cleared when it closes.
  /// The controller never asks who the peer is — it hands a track to
  /// [sourceForTrack] and opens whatever address comes back.
  FundusStreamProxy? proxy;

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

  MediaTracks _tracks = const MediaTracks();

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  double _rate = 1;
  bool _expanded = false;
  bool _chrome = true;
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

  /// What the running file offers in the way of languages and subtitles.
  MediaTracks get tracks => _tracks;
  double get rate => _rate;
  bool get hasWork => _work != null;

  /// Whether the full player covers the content column.
  bool get isExpanded => _expanded;

  /// Whether the controls are shown over the picture. A film wants the
  /// screen; the bar is a guest, exactly as in the reader.
  bool get showsChrome => _chrome;

  void toggleChrome() {
    _chrome = !_chrome;
    notifyListeners();
  }

  void showChrome() {
    if (_chrome) return;
    _chrome = true;
    notifyListeners();
  }

  String? get failure => _failure;

  /// True for the media types that carry a picture.
  bool get showsVideo => switch (_work?.mediaType?.id) {
    'movie' || 'series' || 'anime' => true,
    _ => false,
  };

  /// The video surface of the running engine, or null when there is nothing
  /// to show — no engine yet, or a media type without a picture.
  Widget? videoSurface() => showsVideo ? _engineOrNull?.videoSurface() : null;

  /// The shape of the picture, once the file has said what it is. A player
  /// that assumes 16:9 letterboxes a 4:3 episode a second time.
  ValueListenable<double?> get videoAspectRatio =>
      _engineOrNull?.videoAspectRatio ?? _noAspect;

  static final ValueNotifier<double?> _noAspect = ValueNotifier(null);

  double get progressFraction {
    final total = _duration;
    if (total == null || total.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / total.inMilliseconds).clamp(0, 1);
  }

  /// The frame on screen, or null when there is none to take.
  ///
  /// Only where there is a picture: capturing an audiobook would hand back
  /// the cover, which is not what anyone means by a screenshot.
  Future<Uint8List?> captureFrame() async {
    if (!showsVideo || _engineOrNull == null) return null;
    try {
      return await _engine.screenshot();
    } on Object {
      return null;
    }
  }

  /// A file name for a capture that says where it came from.
  String captureName() {
    final title = _work?.title ?? 'Fundus';
    final at = formatPlaybackTime(_position).replaceAll(':', '-');
    return '${_sanitise(title)}_$at.png';
  }

  static String _sanitise(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// Picks an audio track, and remembers the *language* it was.
  ///
  /// Remembering the id would remember nothing: it is a position inside one
  /// file, and the next episode may well have German second instead of first.
  Future<void> selectAudioTrack(String id) async {
    await _engine.selectAudioTrack(id);
    final chosen = _tracks.audio.where((track) => track.id == id).firstOrNull;
    if (chosen?.language case final language?) {
      preference = preference.withAudio(language);
      await onPreferenceChanged?.call(preference);
    }
  }

  Future<void> selectSubtitleTrack(String id) async {
    await _engine.selectSubtitleTrack(id);
    if (id == 'no') {
      preference = preference.withSubtitle(TrackPreference.off);
    } else {
      final chosen = _tracks.subtitles
          .where((track) => track.id == id)
          .firstOrNull;
      if (chosen?.language case final language?) {
        preference = preference.withSubtitle(language);
      }
    }
    await onPreferenceChanged?.call(preference);
  }

  /// Applies the remembered languages to a file that has just reported its
  /// tracks.
  ///
  /// Only once per file, and only where the file actually has the language:
  /// overriding the file's own choice with nothing would be worse than the
  /// choice it made.
  Future<void> _applyPreference() async {
    if (_appliedPreference || _tracks.audio.isEmpty) return;
    _appliedPreference = true;
    if (preference.audioFor(_tracks.audio) case final track?) {
      if (track.id != _tracks.selectedAudioId) {
        await _engine.selectAudioTrack(track.id);
      }
    }
    if (preference.subtitleFor(_tracks.subtitles) case final track?) {
      if (track.id != _tracks.selectedSubtitleId) {
        await _engine.selectSubtitleTrack(track.id);
      }
    }
  }

  /// States plainly that this work cannot be opened yet.
  ///
  /// Better than handing a comic or an EPUB to libmpv: that plays nothing and
  /// says nothing, which from the outside is a broken button.
  void reject(WorkView work, String message) {
    _work = work;
    _sources = const [];
    _chapters = const [];
    _position = Duration.zero;
    _duration = null;
    _expanded = false;
    _failure = message;
    notifyListeners();
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
    _chrome = true;

    try {
      final tracks = library.playbackTracks(work.id);
      if (tracks.isEmpty) {
        _failure = 'Zu diesem Werk sind keine abspielbaren Dateien erfasst.';
        notifyListeners();
        return;
      }
      _sources = [
        for (final track in tracks)
          sourceForTrack(track, origin: work.origin, proxy: proxy),
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
    // The tracks belong to the file, not to the work: a new file starts
    // without a menu until the engine has said what it holds — and the
    // remembered language is applied again, because the next file numbers
    // its tracks however it likes.
    _tracks = const MediaTracks();
    _appliedPreference = false;
    if (!await source.isReachable()) {
      // A file that is gone is a state, not a crash: the work keeps its
      // progress and the origin mark tells the story.
      _failure = 'Die Datei „${source.title}" ist nicht erreichbar.';
      notifyListeners();
      return;
    }
    // Erst der bekannte Stand, dann öffnen: die Engine meldet die Länge
    // während des Öffnens, und eine Zuweisung danach hat sie bisher wieder
    // auf null gesetzt — bei Video, wo der Index keine Länge kennt, blieb
    // deshalb „--:--" stehen.
    _duration = source.duration;
    _position = at;
    final uri = await source.resolve();
    await _engine.open(uri, start: at);
    _startSaveTimer();
  }

  void _attachStreams() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.addAll([
      _engine.positionStream.listen((value) {
        final previous = _position;
        _position = value;
        // mpv meldet die Position vielfach pro Sekunde. Jede Meldung baute
        // bisher den ganzen Baum neu — sichtbar wird davon aber nur die
        // Sekunde, also wird auch nur dafür neu gebaut. Das Ruckeln kam
        // daher, dass über dem laufenden Bild ständig alles neu entstand.
        if (value.inSeconds != previous.inSeconds) notifyListeners();
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
        if (!value) return;
        if (_sleepingAtChapterEnd) {
          // This is the end the timer was waiting for.
          unawaited(_sleepNow());
          return;
        }
        next();
      }),
      _engine.tracksStream.listen((value) {
        _tracks = value;
        notifyListeners();
        _applyPreference();
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
    if (_engineOrNull != null) await _engine.setRate(_rate);
    // Speed is a habit rather than a property of this file, so it is kept.
    habits = habits.copyWith(rate: _rate);
    await onHabitsChanged?.call(habits);
    notifyListeners();
  }

  Future<void> cycleRate() {
    final steps = PlaybackPreference.rates;
    final index = steps.indexOf(_rate);
    return setRate(steps[(index + 1) % steps.length]);
  }

  /// Skips by the distance this device is set to.
  Future<void> skipBackward() => seekRelative(-habits.skipBack);

  Future<void> skipForward() => seekRelative(habits.skipForward);

  /// Stops playing after a while.
  ///
  /// Falling asleep and finding the position three chapters on is what this
  /// exists to prevent — which is why it can also wait for the end of the
  /// chapter it lands in, rather than cutting a sentence in half.
  void startSleepTimer([Duration? after]) {
    _sleepTimer?.cancel();
    final span = after ?? habits.sleepTimer;
    _sleepEndsAt = DateTime.now().add(span);
    _sleepTimer = Timer(span, _fallAsleep);
    _sleepTick ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepEndsAt = null;
    _sleepingAtChapterEnd = false;
    notifyListeners();
  }

  /// How long the sleep timer still has to run, or null when it is off.
  Duration? get sleepRemaining {
    final ends = _sleepEndsAt;
    if (ends == null) return null;
    final left = ends.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// True once the timer has run out and it is waiting for the chapter to end.
  bool get isSleepingAtChapterEnd => _sleepingAtChapterEnd;

  Future<void> _fallAsleep() async {
    if (habits.sleepAtChapterEnd && _chapterEndsLater) {
      _sleepingAtChapterEnd = true;
      notifyListeners();
      return;
    }
    await _sleepNow();
  }

  Future<void> _sleepNow() async {
    cancelSleepTimer();
    saveProgress();
    if (_engineOrNull != null) await _engine.pause();
  }

  /// Whether the current chapter still has a way to run.
  bool get _chapterEndsLater {
    final total = _duration;
    if (total == null) return false;
    return total - _position > const Duration(seconds: 3);
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
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
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
