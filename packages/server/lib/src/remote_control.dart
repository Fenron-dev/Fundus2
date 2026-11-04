/// What the machine running this server is playing right now.
final class FundusRemoteState {
  const FundusRemoteState({
    this.libraryId,
    this.workId,
    this.title,
    this.trackTitle,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
  });

  /// Nothing open: the player is idle.
  static const idle = FundusRemoteState();

  final String? libraryId;
  final String? workId;
  final String? title;
  final String? trackTitle;
  final bool playing;
  final Duration position;
  final Duration? duration;

  bool get isIdle => workId == null;
}

/// The commands a paired phone may send to the player here.
enum FundusRemoteAction {
  pause,
  resume,
  seek,
  skipForward,
  skipBackward,
  next,
  previous,
  stop;

  static FundusRemoteAction? parse(Object? value) => switch (value) {
    'pause' => pause,
    'resume' => resume,
    'seek' => seek,
    'skip_forward' => skipForward,
    'skip_backward' => skipBackward,
    'next' => next,
    'previous' => previous,
    'stop' => stop,
    _ => null,
  };
}

/// The player of the machine that shares its libraries, as a server sees it.
///
/// The app implements it; the server only checks who asks and what they may
/// see before passing a request on.
abstract interface class FundusRemoteControl {
  FundusRemoteState state();

  /// Starts a work of a shared library, where it was left. False when the
  /// work cannot be played here.
  Future<bool> playWork(String libraryId, String workId);

  Future<void> command(FundusRemoteAction action, {Duration? position});
}
