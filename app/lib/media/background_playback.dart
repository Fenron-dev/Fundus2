import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../app/fundus_log.dart';

import '../data/work_view.dart';
import 'playback_controller.dart';

/// Keeping playback alive when the app is not on screen.
///
/// Android stops a process whose only claim to life is a window that is no
/// longer visible; an audiobook then dies mid-sentence. A media session with
/// a notification is what tells the system this process is doing something,
/// and it is also what puts the controls on the lock screen.
///
/// The player knows nothing about any of this. The handler listens to it and
/// mirrors what it sees, so the rules stay in one place and stay testable
/// without a notification tray.
final class FundusAudioHandler extends BaseAudioHandler {
  FundusAudioHandler(this._player) {
    _player.addListener(_publish);
    _player.positionListenable.addListener(_publishPosition);
    _publish();
  }

  final PlaybackController _player;
  final List<StreamSubscription<dynamic>> _focusSubscriptions = [];

  /// Was die Sitzung für ein geschütztes Werk meldet.
  static const privateMediaId = 'fundus-private';
  static const privateTitle = 'Wiedergabe läuft';
  AudioSession? _session;
  bool _hasFocus = false;

  /// Starts the media session, or does nothing where there is none to start.
  ///
  /// Only Android needs it today. macOS keeps a process alive on its own, and
  /// starting a session there would buy a notification nobody asked for.
  static Future<FundusAudioHandler?> attach(PlaybackController player) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    // Fail closed if native focus setup fails: never mix audio silently.
    player.requestAudioFocus = () async => false;
    try {
      final handler = await AudioService.init(
        builder: () => FundusAudioHandler(player),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.fundus.playback',
          androidNotificationChannelName: 'Wiedergabe',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      await handler._configureAudioFocus();
      return handler;
    } on Object catch (error) {
      // A missing session costs background playback, not the app.
      debugPrint('Hintergrundwiedergabe nicht verfügbar: $error');
      FundusLog.instance.warn('audio.session.failed', {'error': '$error'});
      return null;
    }
  }

  Future<void> _configureAudioFocus() async {
    final session = _session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration.music().copyWith(
        androidWillPauseWhenDucked: true,
      ),
    );
    _player.requestAudioFocus = () async {
      if (_hasFocus) return true;
      return _hasFocus = await session.setActive(true);
    };
    _player.releaseAudioFocus = () async {
      _hasFocus = false;
      await session.setActive(false);
    };
    _focusSubscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (!event.begin) return;
        _hasFocus = false;
        FundusLog.instance.info('audio.interruption', {
          'type': event.type.name,
        });
        // Do not restart behind another player when it later gives focus back.
        // Includes duck requests: spoken chapters should not be talked over.
        unawaited(_player.pause());
      }),
    );
    _focusSubscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        FundusLog.instance.info('audio.headphones.disconnected');
        unawaited(_player.pause());
      }),
    );
  }

  void _publish() {
    final work = _player.work;
    if (work == null) {
      mediaItem.add(null);
      playbackState.add(
        PlaybackState(processingState: AudioProcessingState.idle),
      );
      return;
    }

    // Ein geschütztes Werk bleibt auch auf dem Sperrbildschirm, in der
    // Benachrichtigung und auf dem Autodisplay ungenannt — ohne Titel, ohne
    // Untertitel und ohne Cover. Die Knöpfe funktionieren trotzdem.
    final private = _player.isPrivateWork?.call(work) ?? false;
    mediaItem.add(
      private
          ? MediaItem(
              id: privateMediaId,
              title: privateTitle,
              album: 'Fundus',
              duration: _player.duration,
            )
          : MediaItem(
              id: _player.currentSource?.fileId ?? work.id,
              title: _player.currentSource?.title ?? work.title,
              album: work.title,
              artist: work.subtitle.isEmpty ? null : work.subtitle,
              duration: _player.duration,
              artUri: work.coverPath == null ? null : Uri.file(work.coverPath!),
            ),
    );

    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (_player.isPlaybackRequested)
            MediaControl.pause
          else
            MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState:
            _player.isLoadingTrack ||
                (_player.isPlaybackRequested && !_player.isPlaying)
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: _player.isPlaybackRequested,
        updatePosition: _player.position,
        speed: _player.rate,
      ),
    );
  }

  /// Position ticks no longer invalidate the complete application tree. The
  /// Android media session still receives them through its own narrow path.
  void _publishPosition() {
    final current = playbackState.value;
    if (_player.work == null) return;
    playbackState.add(
      current.copyWith(updatePosition: _player.position, speed: _player.rate),
    );
  }

  static const _recent = 'fundus-recent';
  static const _audiobooks = 'fundus-audiobooks';
  static const _podcasts = 'fundus-podcasts';
  static const _music = 'fundus-music';
  static const _workPrefix = 'work:';

  /// Only what plays without a screen belongs in a car.
  static const _audioKinds = {'audiobook', 'podcast', 'album', 'music'};

  /// Works the car may show: audio, and nothing the protection mode hides.
  List<WorkView> _browsable() {
    final all = _player.browsableWorks?.call() ?? const <WorkView>[];
    final private = _player.isPrivateWork;
    return [
      for (final work in all)
        if (_audioKinds.contains(work.kind) &&
            !(private?.call(work) ?? work.summary.isHhh))
          work,
    ];
  }

  MediaItem _itemFor(WorkView work) => MediaItem(
    id: '$_workPrefix${work.id}',
    title: work.title,
    artist: work.subtitle.isEmpty ? null : work.subtitle,
    artUri: work.coverPath == null ? null : Uri.file(work.coverPath!),
    playable: true,
  );

  static MediaItem _folder(String id, String title) =>
      MediaItem(id: id, title: title, playable: false);

  /// The tree Android Auto browses: what to continue, then by kind.
  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final works = _browsable();
    List<MediaItem> listed(Iterable<WorkView> selection) => [
      for (final work in selection.take(200)) _itemFor(work),
    ];
    Iterable<WorkView> recent() {
      final started =
          works.where((work) => work.summary.lastListenedAt != null).toList()
            ..sort(
              (a, b) => b.summary.lastListenedAt!.compareTo(
                a.summary.lastListenedAt!,
              ),
            );
      return started.take(20);
    }

    Iterable<WorkView> ofKind(Set<String> kinds) =>
        works.where((work) => kinds.contains(work.kind)).toList()..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    return switch (parentMediaId) {
      AudioService.browsableRootId => [
        _folder(_recent, 'Weiterhören'),
        if (works.any((work) => work.kind == 'audiobook'))
          _folder(_audiobooks, 'Hörbücher'),
        if (works.any((work) => work.kind == 'podcast'))
          _folder(_podcasts, 'Podcasts'),
        if (works.any((work) => work.kind == 'album' || work.kind == 'music'))
          _folder(_music, 'Musik'),
      ],
      AudioService.recentRootId || _recent => listed(recent()),
      _audiobooks => listed(ofKind(const {'audiobook'})),
      _podcasts => listed(ofKind(const {'podcast'})),
      _music => listed(ofKind(const {'album', 'music'})),
      _ => const [],
    };
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    if (!mediaId.startsWith(_workPrefix)) return;
    final workId = mediaId.substring(_workPrefix.length);
    // Only something the car was allowed to list can be started from it.
    if (!_browsable().any((work) => work.id == workId)) return;
    await _player.playWorkById?.call(workId);
  }

  @override
  Future<void> play() {
    if (_player.isPlaybackRequested) return Future.value();
    if (_player.isSpeechSessionActive) {
      return _player.resumeSpeechFromMediaControl?.call() ??
          _player.playOrPause();
    }
    return _player.playOrPause();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> stop() async {
    await _player.close();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Swiping the app away means done, not "keep playing forever".
    await stop();
  }

  void detach() {
    _player.removeListener(_publish);
    _player.positionListenable.removeListener(_publishPosition);
    for (final subscription in _focusSubscriptions) {
      unawaited(subscription.cancel());
    }
    if (_session != null) {
      _player.requestAudioFocus = null;
      _player.releaseAudioFocus = null;
      unawaited(_session!.setActive(false));
    }
  }
}
