/// What a stretch of time looked like: how long, with what, on which days.
///
/// Counted from playback and reading sessions this device recorded. Nothing
/// of it leaves the device; a protected work is left out by whoever asks.
final class UsageSummary {
  const UsageSummary({
    required this.from,
    required this.until,
    this.totalSeconds = 0,
    this.secondsByKind = const {},
    this.secondsByMonth = const {},
    this.topWorks = const [],
    this.activeDays = const {},
    this.finishedWorks = 0,
  });

  final DateTime from;
  final DateTime until;
  final int totalSeconds;

  /// Seconds per work kind: `audiobook`, `movie`, `ebook` and so on.
  final Map<String, int> secondsByKind;

  /// Seconds per calendar month, 1 to 12.
  final Map<int, int> secondsByMonth;

  /// The works with the most time, most first.
  final List<({String workId, String title, String kind, int seconds})>
  topWorks;

  /// Days with any activity, as local midnight.
  final Set<DateTime> activeDays;

  /// Works marked as finished in this stretch.
  final int finishedWorks;

  /// The longest run of consecutive days with activity.
  int get longestStreak {
    final days = activeDays.toList()..sort();
    var longest = 0;
    var current = 0;
    DateTime? previous;
    for (final day in days) {
      current = previous != null && day.difference(previous).inHours.abs() <= 25
          ? current + 1
          : 1;
      if (current > longest) longest = current;
      previous = day;
    }
    return longest;
  }
}
