import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

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

  /// Starts the media session, or does nothing where there is none to start.
  ///
  /// Only Android needs it today. macOS keeps a process alive on its own, and
  /// starting a session there would buy a notification nobody asked for.
  static Future<FundusAudioHandler?> attach(PlaybackController player) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await AudioService.init(
        builder: () => FundusAudioHandler(player),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.fundus.playback',
          androidNotificationChannelName: 'Wiedergabe',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } on Object catch (error) {
      // A missing session costs background playback, not the app.
      debugPrint('Hintergrundwiedergabe nicht verfügbar: $error');
      return null;
    }
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
          if (_player.isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: _player.isPlaying,
        updatePosition: _player.position,
        speed: _player.rate,
      ),
    );
  }

  @override
  Future<void> play() =>
      _player.isPlaying ? Future.value() : _player.playOrPause();

  @override
  Future<void> pause() =>
      _player.isPlaying ? _player.playOrPause() : Future.value();

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

  void detach() => _player.removeListener(_publish);
}
