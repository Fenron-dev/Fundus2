import 'package:fundus_server/fundus_server.dart';

import '../media/playback_controller.dart';
import 'library_controller.dart';
import 'work_view.dart';

/// This machine's player, as a paired phone steering it sees it.
///
/// Only the vault that is open here can be played: the player has no other
/// library to read from, and quietly opening another would surprise whoever
/// sits at the screen.
final class PlayerRemoteControl implements FundusRemoteControl {
  PlayerRemoteControl({
    required this.player,
    required this.library,
    required this.play,
  });

  final PlaybackController player;
  final LibraryController library;
  final Future<void> Function(WorkView work) play;

  String? get _libraryId => library.library?.manifest.libraryId;

  @override
  FundusRemoteState state() {
    final work = player.work;
    if (work == null) return FundusRemoteState.idle;
    return FundusRemoteState(
      libraryId: _libraryId,
      workId: work.id,
      title: work.title,
      trackTitle: player.currentSource?.title,
      playing: player.isPlaybackRequested,
      position: player.position,
      duration: player.duration,
    );
  }

  @override
  Future<bool> playWork(String libraryId, String workId) async {
    if (libraryId != _libraryId) return false;
    final work = library.workById(workId);
    if (work == null) return false;
    await play(work);
    return player.work?.id == workId && player.failure == null;
  }

  @override
  Future<void> command(FundusRemoteAction action, {Duration? position}) =>
      switch (action) {
        FundusRemoteAction.pause => player.pause(),
        FundusRemoteAction.resume =>
          player.isPlaybackRequested ? Future.value() : player.playOrPause(),
        FundusRemoteAction.seek => player.seek(position ?? Duration.zero),
        FundusRemoteAction.skipForward => player.skipForward(),
        FundusRemoteAction.skipBackward => player.skipBackward(),
        FundusRemoteAction.next => player.next(),
        FundusRemoteAction.previous => player.previous(),
        FundusRemoteAction.stop => player.close(),
      };
}
