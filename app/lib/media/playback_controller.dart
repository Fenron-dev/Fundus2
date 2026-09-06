import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide RepeatMode;
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';

import '../app/fundus_log.dart';
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

  /// Where a track's bytes come from, by the source it belongs to.
  ///
  /// Set by the scope. The controller never asks which machine that is — it
  /// hands a track to [sourceForTrack] and opens whatever address comes back.
  /// Null for a work that lies on this disk, which is what „local" means to
  /// a player.
  FundusStreamProxy? Function(String sourceId)? proxyForSource;

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

  /// Wem die laufende Datei gehört.
  ///
  /// Bei einem Werk ist das für jede Datei dasselbe. Bei einer Liste wechselt
  /// es mitten im Abspielen — und mit ihm das, wohin der Stand geschrieben
  /// wird, welche Kapitel gelten und was in der Leiste steht.
  List<WorkView> _owners = const [];

  /// Der Name der Liste, die läuft, oder null bei einem einzelnen Werk.
  String? _queueName;

  /// Wo jede einzelne Datei dieses Werks steht — nur dort geführt, wo eine
  /// Datei für sich steht.
  Map<String, ({double position, double? total, DateTime updatedAt})> _perFile =
      const {};
  List<bool> _resume = const [];
  List<LibraryPlaybackChapter> _chapters = const [];
  int _index = 0;

  /// The order the tracks are played in — the indices of [_sources], drawn
  /// once when shuffle is switched on and kept until it is switched off or
  /// the queue starts over. Without a kept order, „previous" cannot say what
  /// was actually played and the same track turns up twice in a row.
  List<int> _order = const [];
  final _random = Random();

  MediaTracks _tracks = const MediaTracks();

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  double _rate = 1;
  bool _expanded = false;
  bool _chrome = true;
  String? _failure;

  WorkView? get work => _work;

  /// Der Name der laufenden Liste, wo eine läuft.
  String? get queueName => _queueName;

  /// Das Werk, zu dem die Datei an [index] gehört — für eine Liste, in der
  /// jede Zeile von woanders kommt.
  WorkView? ownerAt(int index) =>
      index >= 0 && index < _owners.length ? _owners[index] : _work;

  List<MediaByteSource> get sources => _sources;
  List<LibraryPlaybackChapter> get chapters => _chapters;

  /// The chapters inside the file that is playing.
  ///
  /// A podcast is a folder of episodes, so the work's chapter list is a list
  /// of episodes; what is inside one of them is a separate question, and only
  /// worth asking about the file actually running.
  List<LibraryPlaybackChapter> get trackChapters => _trackChapters;
  List<LibraryPlaybackChapter> _trackChapters = const [];

  /// The picture belonging to where we are now, where the file carries one.
  String? get chapterImagePath {
    String? path;
    for (final chapter in _trackChapters) {
      if (chapter.position > _position) break;
      if (chapter.imagePath != null) path = chapter.imagePath;
    }
    return path;
  }

  /// The name of the chapter running now, for the line under the title.
  String? get chapterTitle {
    String? title;
    for (final chapter in _trackChapters) {
      if (chapter.position > _position) break;
      if (chapter.title.isNotEmpty) title = chapter.title;
    }
    return title;
  }

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
    // Which language ends up playing decides the subtitles, so the audio is
    // settled first and the answer handed on: the rule is about what came
    // out, not about what was asked for.
    var spoken = _tracks.audio
        .where((track) => track.id == _tracks.selectedAudioId)
        .firstOrNull
        ?.language;
    if (preference.audioFor(_tracks.audio) case final track?) {
      spoken = track.language ?? spoken;
      if (track.id != _tracks.selectedAudioId) {
        await _engine.selectAudioTrack(track.id);
      }
    }
    if (preference.subtitleFor(_tracks.subtitles, spokenLanguage: spoken)
        case final track?) {
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
    _owners = const [];
    _queueName = null;
    _order = const [];
    _chapters = const [];
    _trackChapters = const [];
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
    String? startAt,
  }) async {
    _failure = null;
    _library = library;
    _work = work;
    // Starting a title opens the player; minimising is the deliberate step.
    _expanded = autoplay;
    _chrome = true;

    final span = FundusLog.instance.start('player.open', {
      'work': work.title,
      'kind': work.kind,
    });
    try {
      final tracks = library.playbackTracks(work.id);
      span.step('tracks', {'count': tracks.length});
      if (tracks.isEmpty) {
        _failure = 'Zu diesem Werk sind keine abspielbaren Dateien erfasst.';
        notifyListeners();
        return;
      }
      _sources = [
        for (final track in tracks)
          sourceForTrack(
            track,
            origin: work.origin,
            proxy: proxyForSource?.call(track.sourceId),
          ),
      ];
      _owners = [for (final _ in tracks) work];
      _resume = const [];
      _queueName = null;
      _chapters = await library.playbackChapters(work.id);
      span.step('chapters', {'count': _chapters.length});
      _buildOrder();
      _attachStreams();

      // Wer eine bestimmte Folge angetippt hat, meint diese Folge — nicht
      // die Stelle, an der das Werk zuletzt stand.
      final chosen = startAt == null
          ? -1
          : _sources.indexWhere((source) => source.fileId == startAt);
      final saved = chosen >= 0 ? null : library.loadProgress(work.id);
      final startIndex = chosen >= 0
          ? chosen
          : saved?.fileId == null
          ? 0
          : _sources.indexWhere((s) => s.fileId == saved!.fileId);
      _index = startIndex < 0 ? 0 : startIndex;
      // Eine Folge, die jemand antippt, fängt dort an, wo er sie verlassen
      // hat — dafür wird der Stand je Datei geführt.
      if (work.mediaType?.keepsPositionPerFile ?? false) {
        _perFile = library.filePositions(work.id);
      } else {
        _perFile = const {};
      }
      final resumeAt = chosen >= 0
          ? _startOfFile(_sources[_index].fileId)
          : saved == null
          ? Duration.zero
          : Duration(
              milliseconds: ((saved.position.numericValue ?? 0) * 1000).round(),
            );
      await _openCurrent(at: resumeAt);
      if (autoplay) await _engine.play();
      span.done();
    } on Object catch (error) {
      span.failed(error);
      _failure = error.toString();
    }
    notifyListeners();
  }

  /// Spielt eine Liste, deren Zeilen aus verschiedenen Werken kommen.
  ///
  /// Der Unterschied zu [open] ist genau einer: welches Werk gerade läuft,
  /// steht nicht mehr fest. Der Stand wird deshalb dem Werk der laufenden
  /// Zeile gutgeschrieben, und beim Übergang von einer Zeile zur nächsten
  /// wird der alte Stand vorher weggeschrieben — sonst verlöre eine Liste
  /// unterwegs genau das, wofür man sie hört.
  Future<void> openQueue(
    FundusLibrary library,
    List<QueueEntry> entries, {
    String? name,
    int startIndex = 0,
    bool autoplay = true,
  }) async {
    _failure = null;
    _library = library;
    _queueName = name;
    _expanded = autoplay;
    _chrome = true;
    if (entries.isEmpty) {
      _failure = 'In dieser Liste steht nichts, was sich abspielen lässt.';
      _work = null;
      _sources = const [];
      _owners = const [];
      notifyListeners();
      return;
    }
    final span = FundusLog.instance.start('player.queue', {
      'name': name ?? '',
      'count': entries.length,
    });
    try {
      _sources = [
        for (final entry in entries)
          sourceForTrack(
            entry.track,
            origin: entry.work.origin,
            proxy: proxyForSource?.call(entry.track.sourceId),
          ),
      ];
      _owners = [for (final entry in entries) entry.work];
      _resume = [for (final entry in entries) entry.resume];
      _index = startIndex.clamp(0, _sources.length - 1);
      _work = _owners[_index];
      _chapters = await library.playbackChapters(_work!.id);
      _buildOrder();
      _attachStreams();
      await _openCurrent(at: _startOf(_index));
      if (autoplay) await _engine.play();
      span.done();
    } on Object catch (error) {
      span.failed(error);
      _failure = error.toString();
    }
    notifyListeners();
  }

  /// Wo eine Zeile anfängt.
  ///
  /// Ein einzelner Titel fängt vorn an — wer ihn in eine Liste gelegt hat,
  /// meint den Titel, nicht die Stelle. Ein ganzes Werk in einer Liste ist
  /// dagegen ein Hörbuch oder eine Folge, und die macht dort weiter, wo sie
  /// stand.
  /// Wo eine Datei zuletzt stand. Ganz am Ende zählt als „von vorn": eine
  /// zu Ende gehörte Folge noch einmal zu starten heißt, sie zu hören.
  Duration _startOfFile(String fileId) {
    final saved = _perFile[fileId];
    if (saved == null || saved.position <= 0) return Duration.zero;
    final total = saved.total;
    if (total != null && total - saved.position < 15) return Duration.zero;
    return Duration(milliseconds: (saved.position * 1000).round());
  }

  Duration _startOf(int index) {
    final library = _library;
    final owner = ownerAt(index);
    if (library == null || owner == null) return Duration.zero;
    if (index >= _resume.length || !_resume[index]) return Duration.zero;
    final saved = library.loadProgress(owner.id);
    if (saved == null || saved.fileId != _sources[index].fileId) {
      return Duration.zero;
    }
    return Duration(
      milliseconds: ((saved.position.numericValue ?? 0) * 1000).round(),
    );
  }

  Future<void> _openCurrent({Duration at = Duration.zero}) async {
    final source = currentSource;
    if (source == null) return;
    // Wechselt die Zeile das Werk, gehört der bisherige Stand noch dem alten
    // — geschrieben wird er, bevor das neue übernimmt.
    final owner = ownerAt(_index);
    if (owner != null && owner.id != _work?.id) {
      saveProgress();
      _work = owner;
      _chapters = await _library?.playbackChapters(owner.id) ?? const [];
    }
    // The tracks belong to the file, not to the work: a new file starts
    // without a menu until the engine has said what it holds — and the
    // remembered language is applied again, because the next file numbers
    // its tracks however it likes.
    _tracks = const MediaTracks();
    _trackChapters = const [];
    _appliedPreference = false;
    _clearBetweenEpisodes();
    final reach = Stopwatch()..start();
    final reachable = await source.isReachable();
    if (reach.elapsedMilliseconds > 200) {
      FundusLog.instance.write(LogLevel.warn, 'player.reachable.slow', {
        'file': source.title,
      }, reach.elapsed);
    }
    if (!reachable) {
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
    final span = FundusLog.instance.start('player.file', {
      'file': source.title,
      'origin': source.origin.name,
    });
    final uri = await source.resolve();
    span.step('resolved');
    await _engine.open(uri, start: at);
    span.done();
    _startSaveTimer();
    // After playback has started, never before it: reading the chapters means
    // walking the file's tags, and nobody should wait for a picture.
    unawaited(_loadTrackChapters(source.fileId));
  }

  /// Reads the chapters of the running file in the background.
  Future<void> _loadTrackChapters(String fileId) async {
    final library = _library;
    final work = _work;
    if (library == null || work == null) return;
    if (!(work.mediaType?.hasChapterImages ?? false)) return;
    try {
      final chapters = await library.trackChapters(work.id, fileId);
      if (currentSource?.fileId != fileId) return;
      _trackChapters = chapters;
      notifyListeners();
    } on Object catch (failure) {
      FundusLog.instance.warn('player.chapters', {'error': '$failure'});
    }
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
        _finished();
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

  /// Pressing „weiter" always moves on.
  ///
  /// „Titel wiederholen" is about what happens when a track *ends*; someone
  /// who asks for the next one is not asking for this one again.
  Future<void> next() async {
    final target = _nextIndex(manual: true);
    if (target == null) {
      await _engine.pause();
      _markFinished();
      return;
    }
    _index = target;
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  Future<void> previous() async {
    // Like every player: back jumps to the start of the track first.
    final at = _orderPosition;
    if (_position > const Duration(seconds: 3) || at <= 0) {
      await seek(Duration.zero);
      return;
    }
    _index = _order[at - 1];
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  /// Where the current track sits in the playing order.
  int get _orderPosition {
    final at = _order.indexOf(_index);
    return at < 0 ? 0 : at;
  }

  /// What plays after this one, or null when nothing does.
  int? _nextIndex({bool manual = false}) {
    if (_sources.isEmpty) return null;
    if (!manual && habits.repeat == RepeatMode.one) return _index;
    final at = _orderPosition;
    if (at + 1 < _order.length) return _order[at + 1];
    if (habits.repeat == RepeatMode.none) return null;
    // Round again. A fresh draw, or the same album would repeat in the same
    // „random" order every time.
    if (habits.shuffle) _drawOrder(startingWith: null);
    return _order.isEmpty ? null : _order.first;
  }

  /// Builds the playing order for the tracks now loaded.
  void _buildOrder() {
    if (habits.shuffle) {
      _drawOrder(startingWith: _index);
    } else {
      _order = [for (var index = 0; index < _sources.length; index++) index];
    }
  }

  void _drawOrder({required int? startingWith}) {
    final rest = [
      for (var index = 0; index < _sources.length; index++)
        if (index != startingWith) index,
    ]..shuffle(_random);
    _order = [?startingWith, ...rest];
  }

  /// Draws a new order, or puts the tracks back in the order they are in.
  Future<void> setShuffle(bool value) async {
    habits = habits.copyWith(shuffle: value);
    _buildOrder();
    await onHabitsChanged?.call(habits);
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    habits = habits.copyWith(repeat: habits.repeat.next);
    await onHabitsChanged?.call(habits);
    notifyListeners();
  }

  bool get isShuffling => habits.shuffle;
  RepeatMode get repeatMode => habits.repeat;

  /// Whether shuffle and repeat mean anything here.
  ///
  /// One file has nothing to shuffle, and a film is not a queue.
  bool get hasQueueControls => _sources.length > 1 && !showsVideo;

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= _sources.length) return;
    // Erst festhalten, wo die laufende Folge steht, dann wechseln.
    saveProgress();
    _index = index;
    await _openCurrent(at: _startOfFile(_sources[index].fileId));
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

  /// An episode has ended.
  ///
  /// A series goes on: the next one starts by itself after a moment, with the
  /// moment being what makes it stoppable. Anything else — an audiobook's
  /// next file, a single film — behaves as it always did, because there is
  /// nothing to decide.
  void _finished() {
    final target = _nextIndex();
    if (target == null) {
      saveProgress();
      notifyListeners();
      return;
    }
    if (!showsVideo) {
      unawaited(_playIndex(target));
      return;
    }
    _nextIn = habits.autoplayNext ? habits.autoplayDelay : null;
    _betweenEpisodes = true;
    _chrome = true;
    notifyListeners();
    if (_nextIn == null) return;
    _nextTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = (_nextIn ?? Duration.zero) - const Duration(seconds: 1);
      if (left <= Duration.zero) {
        playNextNow();
        return;
      }
      _nextIn = left;
      notifyListeners();
    });
  }

  Timer? _nextTick;
  Duration? _nextIn;
  bool _betweenEpisodes = false;

  /// True while the „next episode" card is up.
  bool get isBetweenEpisodes => _betweenEpisodes;

  /// How long until the next one starts, or null when it will not.
  Duration? get nextEpisodeIn => _nextIn;

  /// The title of what comes next, for the card to name.
  String? get nextEpisodeTitle {
    final at = _orderPosition;
    if (at + 1 >= _order.length) return null;
    return _sources[_order[at + 1]].title;
  }

  Future<void> _playIndex(int index) async {
    _index = index;
    await _openCurrent();
    await _engine.play();
    notifyListeners();
  }

  void playNextNow() {
    _clearBetweenEpisodes();
    next();
  }

  /// Stays where it is. The episode stands finished and nothing starts.
  void stayHere() {
    _clearBetweenEpisodes();
    saveProgress();
    notifyListeners();
  }

  void _clearBetweenEpisodes() {
    _nextTick?.cancel();
    _nextTick = null;
    _nextIn = null;
    _betweenEpisodes = false;
  }

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
    _owners = const [];
    _resume = const [];
    _perFile = const {};
    _queueName = null;
    _order = const [];
    _chapters = const [];
    _trackChapters = const [];
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
      // Und bei einer Folge zusätzlich dort, wo sie hingehört: an der Datei.
      // Der Stand des Werks zeigt immer nur auf eine — wer zwischen zwei
      // Folgen wechselt, verlöre sonst jedes Mal die andere.
      if (work.mediaType?.keepsPositionPerFile ?? false) {
        if (finished) {
          library.clearFilePosition(workId: work.id, fileId: source.fileId);
          _perFile = {..._perFile}..remove(source.fileId);
        } else {
          final seconds = _position.inMilliseconds / 1000;
          final total = _duration == null
              ? null
              : _duration!.inMilliseconds / 1000;
          library.saveFilePosition(
            workId: work.id,
            fileId: source.fileId,
            position: seconds,
            total: total,
          );
          // Auch hier behalten: wer innerhalb einer Sitzung zwischen zwei
          // Folgen hin und her springt, soll nicht den Stand von vorhin
          // wiederfinden.
          _perFile = {
            ..._perFile,
            source.fileId: (
              position: seconds,
              total: total ?? _perFile[source.fileId]?.total,
              updatedAt: DateTime.now().toUtc(),
            ),
          };
        }
      }
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
    _nextTick?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _engineOrNull?.dispose();
    super.dispose();
  }
}

/// Eine Zeile einer laufenden Liste.
///
/// Werk und Datei zusammen: die Datei sagt, was klingt, das Werk, wem der
/// Stand gehört und was in der Leiste steht.
final class QueueEntry {
  const QueueEntry({
    required this.work,
    required this.track,
    this.resume = false,
  });

  final WorkView work;
  final LibraryPlaybackTrack track;

  /// Ob diese Zeile dort weitermacht, wo das Werk stand — wahr für ein
  /// ganzes Werk, falsch für einen einzelnen Titel.
  final bool resume;
}

/// Formats a duration the way the player shows it.
String formatPlaybackTime(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
