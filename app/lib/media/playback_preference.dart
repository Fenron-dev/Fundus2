import 'package:fundus_core/fundus_core.dart';

/// What happens when the queue runs out.
///
/// The modes themselves are [RepeatMode] from the core, where a playback
/// session already records them; this is only how they are stepped through
/// and named on a button.
extension RepeatModeCycle on RepeatMode {
  RepeatMode get next => switch (this) {
    RepeatMode.none => RepeatMode.all,
    RepeatMode.all => RepeatMode.one,
    RepeatMode.one => RepeatMode.none,
  };

  String get label => switch (this) {
    RepeatMode.none => 'Keine Wiederholung',
    RepeatMode.all => 'Alles wiederholen',
    RepeatMode.one => 'Titel wiederholen',
  };
}

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
    this.autoplayNext = true,
    this.autoplayDelay = const Duration(seconds: 8),
    this.shuffle = false,
    this.repeat = RepeatMode.none,
  });

  factory PlaybackPreference.fromJson(Map<String, Object?> value) =>
      PlaybackPreference(
        rate: _rateOf(value['rate']),
        skipBack: _secondsOf(value['skip_back'], 15),
        skipForward: _secondsOf(value['skip_forward'], 30),
        sleepTimer: _minutesOf(value['sleep_timer_minutes'], 30),
        sleepAtChapterEnd: value['sleep_at_chapter_end'] != false,
        autoplayNext: value['autoplay_next'] != false,
        autoplayDelay: _secondsOf(value['autoplay_delay'], 8),
        shuffle: value['shuffle'] == true,
        repeat: _repeatOf(value['repeat']),
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

  /// Whether the next episode starts on its own when one ends.
  ///
  /// On for video, because that is what a series is for, and off is one
  /// switch away for the evening where it is not.
  final bool autoplayNext;

  /// How long the „Nächste Folge" card stands before it does. Long enough to
  /// stop it, short enough not to be a pause.
  final Duration autoplayDelay;

  /// Whether the tracks are played in an order drawn once rather than in the
  /// order they are in.
  ///
  /// Drawn once and kept: „zufällig" that redraws on every step cannot say
  /// what came before, and would play the same track twice in a row often
  /// enough to look broken.
  final bool shuffle;

  final RepeatMode repeat;

  static const rates = <double>[0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
  static const skips = <int>[5, 10, 15, 30, 45, 60, 90];
  static const sleepChoices = <int>[5, 10, 15, 30, 45, 60, 90];
  static const autoplayDelays = <int>[3, 5, 8, 12, 20];

  Map<String, Object?> toJson() => {
    'rate': rate,
    'skip_back': skipBack.inSeconds,
    'skip_forward': skipForward.inSeconds,
    'sleep_timer_minutes': sleepTimer.inMinutes,
    'sleep_at_chapter_end': sleepAtChapterEnd,
    'autoplay_next': autoplayNext,
    'autoplay_delay': autoplayDelay.inSeconds,
    'shuffle': shuffle,
    'repeat': repeat.name,
  };

  PlaybackPreference copyWith({
    double? rate,
    Duration? skipBack,
    Duration? skipForward,
    Duration? sleepTimer,
    bool? sleepAtChapterEnd,
    bool? autoplayNext,
    Duration? autoplayDelay,
    bool? shuffle,
    RepeatMode? repeat,
  }) => PlaybackPreference(
    rate: rate ?? this.rate,
    skipBack: skipBack ?? this.skipBack,
    skipForward: skipForward ?? this.skipForward,
    sleepTimer: sleepTimer ?? this.sleepTimer,
    sleepAtChapterEnd: sleepAtChapterEnd ?? this.sleepAtChapterEnd,
    autoplayNext: autoplayNext ?? this.autoplayNext,
    autoplayDelay: autoplayDelay ?? this.autoplayDelay,
    shuffle: shuffle ?? this.shuffle,
    repeat: repeat ?? this.repeat,
  );

  static RepeatMode _repeatOf(Object? value) =>
      RepeatMode.values.where((mode) => mode.name == value).firstOrNull ??
      RepeatMode.none;

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
