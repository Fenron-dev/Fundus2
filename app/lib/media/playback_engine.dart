import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/fundus_log.dart';

/// One selectable track of a file — a language, a commentary, a subtitle.
final class MediaTrackOption {
  const MediaTrackOption({
    required this.id,
    required this.label,
    this.language,
  });

  final String id;
  final String label;

  /// The language the file names for this track, if it names one.
  ///
  /// Track *ids* are positions in one file and mean nothing in the next, so a
  /// remembered choice has to be remembered as a language. Episode two of the
  /// same series can have its tracks in the other order.
  final String? language;
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

  /// The shape of the picture, once the file has reported one.
  ///
  /// A player that guesses 16:9 letterboxes a 4:3 episode twice and crops
  /// nothing correctly. Null until the engine knows, and for engines that
  /// have no picture at all.
  ValueListenable<double?> get videoAspectRatio;

  /// The picture as it stands, for engines that have one. Null means there is
  /// nothing to capture — an audiobook has no frame.
  Future<Uint8List?> screenshot();

  Future<void> dispose();

  /// The picture, for engines that have one. Null means audio only.
  Widget? videoSurface();
}

/// The real engine: libmpv through media_kit.
final class MediaKitEngine implements PlaybackEngine {
  /// Read-ahead for libmpv's demuxer.
  ///
  /// The default is 32 MiB. That is enough for a local SSD, but a mounted
  /// SMB/NFS file can briefly stall while the share answers the next range
  /// request. A moderate 64 MiB cache smooths those short pauses without
  /// turning Fundus into a full-file downloader. Offline copies and peer
  /// streaming remain the right answer for a slow or unreliable connection.
  static const _bufferSize = 64 * 1024 * 1024;

  MediaKitEngine([Player? player])
    : _player =
          player ??
          Player(
            configuration: const PlayerConfiguration(
              bufferSize: _bufferSize,
              logLevel: MPVLogLevel.warn,
            ),
          ) {
    // The video output has to exist before the first file is opened —
    // attaching it afterwards leaves the picture black while the sound plays.
    _video = VideoController(_player);
    _nativeTuning = _configureNativePlayback();
    // The rect the engine actually decodes, so the frame around it can be the
    // right shape rather than a guess.
    _video.rect.addListener(() {
      final rect = _video.rect.value;
      _aspect.value = rect == null || rect.width <= 0 || rect.height <= 0
          ? null
          : rect.width / rect.height;
    });
    _trackSubscriptions.addAll([
      _player.stream.tracks.listen((value) {
        _available = value;
        _emitTracks();
      }),
      _player.stream.track.listen((value) {
        _selected = value;
        _emitTracks();
      }),
      _player.stream.buffering.distinct().listen((active) {
        FundusLog.instance.info('player.buffering', {
          'active': active,
          'position_ms': _player.state.position.inMilliseconds,
          'buffer_ms': _player.state.buffer.inMilliseconds,
          'percent': _player.state.bufferingPercentage,
        });
      }),
      _player.stream.log
          .where((entry) => entry.level == 'warn' || entry.level == 'error')
          .listen((entry) {
            FundusLog.instance.warn('player.native', {
              'source': entry.prefix,
              'level': entry.level,
              'message': entry.text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
            });
          }),
      _player.stream.error.listen((message) {
        FundusLog.instance.warn('player.native.error', {'message': message});
      }),
    ]);
    if (_isWindows) {
      _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_player.state.playing) unawaited(_recordNativeHealth('playing'));
      });
    }
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
                language: track.language,
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
              language: track.language,
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
  late final Future<void> _nativeTuning;
  Timer? _healthTimer;
  bool _healthReading = false;

  /// Gives libmpv enough material ahead of the playhead without making it
  /// stop the clock merely because the cache briefly falls below a target.
  ///
  /// `bufferSize` alone only caps the cache; without a time target mpv can
  /// still hover close to the playhead on a mounted SMB/NFS file. Desktop
  /// display-resampling also avoids the periodic repeated/dropped frame that
  /// 23.976/24 fps material otherwise shows on a 60 Hz desktop.
  Future<void> _configureNativePlayback() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final properties = <String, String>{
      'cache': 'yes',
      'demuxer-readahead-secs': '30',
      // `cache-pause=yes` produced a very characteristic one-second cadence
      // on SMB/NFS and slower peer streams: play until the target is missed,
      // wait, play, wait. Let mpv consume its read-ahead continuously instead.
      'cache-pause': 'no',
      if (_isWindows) ...{
        // mpv's normal 128-KiB low-level reads are specifically inefficient
        // on some network filesystems. Windows SMB showed no buffering event,
        // yet its synchronous small reads could still starve presentation.
        'stream-buffer-size': '4MiB',
        // Keep decoded frames away from brief Flutter raster stalls. This is
        // deliberately Windows-only; libavcodec remains multithreaded and the
        // queue is merely a small timing cushion between decode and display.
        'vd-queue-enable': 'yes',
        'vd-queue-max-secs': '2',
      },
      if (_isDesktop) ...{
        // Display resampling plus interpolation is useful on a fast GPU, but
        // it is expensive enough to stall software-decoded video on both
        // Windows and macOS. Audio is the stable clock for media playback;
        // mpv may drop a late frame instead of freezing the entire picture.
        'video-sync': 'audio',
        'interpolation': 'no',
        'framedrop': 'vo',
      },
    };
    for (final property in properties.entries) {
      await platform.setProperty(property.key, property.value);
    }
  }

  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Captures the values needed to tell I/O starvation, software decoding and
  /// presentation stalls apart. Earlier logs only contained `buffering=false`,
  /// which cannot explain dropped or delayed Windows frames.
  Future<void> _recordNativeHealth(String reason) async {
    if (_healthReading) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _healthReading = true;
    const names = [
      'video-codec',
      'hwdec-current',
      'container-fps',
      'estimated-vf-fps',
      'display-fps',
      'avsync',
      'frame-drop-count',
      'decoder-frame-drop-count',
      'mistimed-frame-count',
      'vo-delayed-frame-count',
      'demuxer-cache-duration',
      'cache-buffering-state',
    ];
    try {
      final values = await Future.wait([
        for (final name in names) platform.getProperty(name),
      ]);
      FundusLog.instance.info('player.video.health', {
        'reason': reason,
        'position_ms': _player.state.position.inMilliseconds,
        for (var index = 0; index < names.length; index++)
          if (values[index].isNotEmpty) names[index]: values[index],
      });
    } on Object catch (error) {
      FundusLog.instance.warn('player.video.health.failed', {
        'error': '$error',
      });
    } finally {
      _healthReading = false;
    }
  }

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
    await _nativeTuning;
    final resume = start > Duration.zero ? start : null;
    await _player.open(Media(uri.toString(), start: resume), play: false);
    if (_isWindows) {
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 2),
          () => _recordNativeHealth('opened'),
        ),
      );
    }
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
  Future<Uint8List?> screenshot() =>
      _player.screenshot(format: 'image/png', includeLibassSubtitles: true);

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

  /// Built once and handed out unchanged.
  ///
  /// A fresh widget on every call meant the picture's subtree was rebuilt
  /// with the rest of the screen; the same instance lets Flutter skip it
  /// entirely, which is what the picture needs while it is running.
  late final Widget _surface = RepaintBoundary(
    child: Video(controller: _video, controls: NoVideoControls),
  );

  @override
  Widget? videoSurface() => _surface;

  @override
  ValueListenable<double?> get videoAspectRatio => _aspect;

  final ValueNotifier<double?> _aspect = ValueNotifier(null);

  @override
  Future<void> dispose() async {
    _healthTimer?.cancel();
    for (final subscription in _trackSubscriptions) {
      await subscription.cancel();
    }
    await _tracks.close();
    await _player.dispose();
  }
}
