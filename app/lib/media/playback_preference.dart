/// How this device plays.
///
/// Speed and skip distances are habits, not properties of a work: someone who
/// listens at 1.4× listens to everything at 1.4×, and someone who skips back
/// thirty seconds means thirty everywhere. They are kept per device, in the
/// vault's device profile, so a reinstall does not cost them.
final class PlaybackPreference {
  const PlaybackPreference({
    this.rate = 1,
    this.skipBack = const Duration(seconds: 15),
    this.skipForward = const Duration(seconds: 30),
    this.sleepTimer = const Duration(minutes: 30),
    this.sleepAtChapterEnd = true,
  });

  factory PlaybackPreference.fromJson(Map<String, Object?> value) =>
      PlaybackPreference(
        rate: _rateOf(value['rate']),
        skipBack: _secondsOf(value['skip_back'], 15),
        skipForward: _secondsOf(value['skip_forward'], 30),
        sleepTimer: _minutesOf(value['sleep_timer_minutes'], 30),
        sleepAtChapterEnd: value['sleep_at_chapter_end'] != false,
      );

  /// Playback speed. Bounded on both sides: below a half nothing is
  /// intelligible and above three nothing is either, and an unbounded number
  /// out of a settings file should not be able to make the player unusable.
  final double rate;

  final Duration skipBack;
  final Duration skipForward;

  /// How long the sleep timer runs when it is started without a choice.
  final Duration sleepTimer;

  /// Whether the timer waits for the end of the chapter it lands in.
  ///
  /// Falling asleep mid-sentence and finding the position three chapters on
  /// is the thing a sleep timer exists to prevent; stopping four minutes late
  /// at a chapter break costs nothing by comparison.
  final bool sleepAtChapterEnd;

  static const rates = <double>[0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
  static const skips = <int>[5, 10, 15, 30, 45, 60, 90];
  static const sleepChoices = <int>[5, 10, 15, 30, 45, 60, 90];

  Map<String, Object?> toJson() => {
    'rate': rate,
    'skip_back': skipBack.inSeconds,
    'skip_forward': skipForward.inSeconds,
    'sleep_timer_minutes': sleepTimer.inMinutes,
    'sleep_at_chapter_end': sleepAtChapterEnd,
  };

  PlaybackPreference copyWith({
    double? rate,
    Duration? skipBack,
    Duration? skipForward,
    Duration? sleepTimer,
    bool? sleepAtChapterEnd,
  }) => PlaybackPreference(
    rate: rate ?? this.rate,
    skipBack: skipBack ?? this.skipBack,
    skipForward: skipForward ?? this.skipForward,
    sleepTimer: sleepTimer ?? this.sleepTimer,
    sleepAtChapterEnd: sleepAtChapterEnd ?? this.sleepAtChapterEnd,
  );

  static double _rateOf(Object? value) {
    final number = value is num ? value.toDouble() : 1.0;
    return number.clamp(0.5, 3).toDouble();
  }

  static Duration _secondsOf(Object? value, int fallback) {
    final number = value is num ? value.toInt() : fallback;
    return Duration(seconds: number.clamp(1, 300));
  }

  static Duration _minutesOf(Object? value, int fallback) {
    final number = value is num ? value.toInt() : fallback;
    return Duration(minutes: number.clamp(1, 480));
  }
}
