import 'playback_engine.dart';

/// What a stretch of a film or episode is, where it can be skipped.
enum SkippableKind {
  intro('Intro überspringen'),
  recap('Rückblick überspringen'),
  credits('Abspann überspringen');

  const SkippableKind(this.action);

  /// What the button says.
  final String action;
}

/// One stretch of the file that its own chapter marks call an intro, a
/// recap or the credits.
final class SkippableSegment {
  const SkippableSegment({
    required this.kind,
    required this.start,
    required this.end,
  });

  final SkippableKind kind;
  final Duration start;
  final Duration end;

  bool contains(Duration position) => position >= start && position < end;
}

/// Reads the chapter marks of a file for the parts nobody wants twice.
///
/// Only names are trusted, never a guessed length: a chapter called
/// „Opening" is one, a quiet first minute is not. Anything implausibly long
/// for its kind is left alone rather than skipping half an episode.
List<SkippableSegment> skippableSegments(
  List<FileChapter> chapters, {
  Duration? duration,
}) {
  final sorted = [...chapters]..sort((a, b) => a.start.compareTo(b.start));
  final result = <SkippableSegment>[];
  for (var index = 0; index < sorted.length; index++) {
    final kind = _kindOf(sorted[index].title);
    if (kind == null) continue;
    final start = sorted[index].start;
    final end = index + 1 < sorted.length ? sorted[index + 1].start : duration;
    if (end == null || end <= start) continue;
    if (end - start > _longest[kind]!) continue;
    result.add(SkippableSegment(kind: kind, start: start, end: end));
  }
  return result;
}

const _longest = {
  SkippableKind.intro: Duration(minutes: 4),
  SkippableKind.recap: Duration(minutes: 5),
  SkippableKind.credits: Duration(minutes: 12),
};

SkippableKind? _kindOf(String title) {
  final name = title.toLowerCase().trim();
  if (name.isEmpty) return null;
  bool matches(RegExp pattern) => pattern.hasMatch(name);
  if (matches(
    RegExp(
      r'^(op|op\s?\d+|opening( credits| song| theme)?|intro|vorspann|'
      r'titelsequenz|title sequence|theme song|main titles?)$',
    ),
  )) {
    return SkippableKind.intro;
  }
  if (matches(
    RegExp(
      r'^(recap|previously( on.*)?|zusammenfassung|rückblick|'
      r'was bisher geschah)$',
    ),
  )) {
    return SkippableKind.recap;
  }
  if (matches(
    RegExp(
      r'^(ed|ed\s?\d+|ending( credits| song| theme)?|end credits|credits|'
      r'abspann|outro|closing credits|preview|vorschau|next episode)$',
    ),
  )) {
    return SkippableKind.credits;
  }
  return null;
}
