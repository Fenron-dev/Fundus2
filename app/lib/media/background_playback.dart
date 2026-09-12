import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../app/fundus_log.dart';

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
    _publish();
  }

  final PlaybackController _player;
  final List<StreamSubscription<dynamic>> _focusSubscriptions = [];
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

    mediaItem.add(
      MediaItem(
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

  @override
  Future<void> play() =>
      _player.isPlaybackRequested ? Future.value() : _player.playOrPause();

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
