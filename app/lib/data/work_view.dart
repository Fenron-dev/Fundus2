import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import 'media_type.dart';

/// One work, ready to be drawn.
///
/// The screens never see a database row and never ask where a work came from:
/// origin arrives here as a value, the same way a title does. That is the
/// whole reason there is one library view instead of a local one and a remote
/// one.
final class WorkView {
  const WorkView({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.origin,
    required this.mediaType,
    required this.kind,
    required this.summary,
    this.progressFraction,
    this.progressLabel,
    this.finished = false,
    this.coverPath,
    this.folderPath = '',
  });

  factory WorkView.fromSummary(LibraryWorkSummary summary) {
    final mediaType = MediaTypes.forWorkKind(summary.kind);
    final progress = _progressOf(summary, mediaType?.progressKind);
    return WorkView(
      id: summary.id,
      title: summary.title,
      subtitle: _subtitleOf(summary),
      origin: FundusOrigin.fromAvailability(summary.availability),
      mediaType: mediaType,
      kind: summary.kind,
      summary: summary,
      progressFraction: progress.$1,
      progressLabel: progress.$2,
      finished: summary.progressFinished,
      coverPath: summary.coverPath,
      folderPath: summary.series ?? '',
    );
  }

  final String id;
  final String title;
  final String subtitle;
  final FundusOrigin origin;

  /// Null when nothing claims this work's kind — it stays visible under
  /// "Nicht zugeordnet" instead of disappearing.
  final MediaTypeDefinition? mediaType;
  final String kind;
  final LibraryWorkSummary summary;

  final double? progressFraction;
  final String? progressLabel;
  final bool finished;
  final String? coverPath;
  final String folderPath;

  bool get hasProgress => progressFraction != null && progressFraction! > 0;

  /// Two letters for the placeholder cover, the way the prototype draws them.
  String get initials {
    final words = title.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first
          .substring(0, words.first.length.clamp(0, 2))
          .toUpperCase();
    }
    return words.take(2).map((w) => w[0]).join().toUpperCase();
  }

  static String _subtitleOf(LibraryWorkSummary summary) {
    final parts = <String>[];
    if (summary.series != null && summary.series!.isNotEmpty) {
      final sequence = summary.seriesSequence;
      parts.add(
        sequence == null
            ? summary.series!
            : '${summary.series!} ${_formatSequence(sequence)}',
      );
    }
    if (summary.author.isNotEmpty && summary.author != 'Unbekannt') {
      parts.add(summary.author);
    }
    if (parts.isEmpty && summary.publishedYear != null) {
      parts.add('${summary.publishedYear}');
    }
    return parts.join(' · ');
  }

  static String _formatSequence(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  /// Progress means something different per media type, so the label is built
  /// from the type rather than from a shared percentage.
  static (double?, String?) _progressOf(
    LibraryWorkSummary summary,
    ProgressKind? kind,
  ) {
    if (kind == null || kind == ProgressKind.none) return (null, null);
    if (summary.progressFinished) return (1, 'Fertig');

    final media = summary.mediaProgress;
    final position = summary.progressPosition;
    final total = summary.progressDuration;

    switch (kind) {
      case ProgressKind.seconds:
        if (position == null || total == null || total.inSeconds <= 0) {
          return (null, null);
        }
        final remaining = total - position;
        return (
          position.inSeconds / total.inSeconds,
          'noch ${_formatRemaining(remaining)}',
        );
      case ProgressKind.pagePerVolume:
        if (media == null) return (null, null);
        final page = media.numericValue?.round();
        final pages = media.total?.round();
        if (page == null) return (null, null);
        return (
          media.fraction,
          pages == null ? 'Seite $page' : 'Seite $page von $pages',
        );
      case ProgressKind.chapterFraction:
        if (media == null) return (null, null);
        final fraction = media.scrollOffset ?? media.fraction;
        final chapter = media.label ?? media.chapterId;
        return (
          fraction,
          chapter == null
              ? null
              : fraction == null
              ? chapter
              : '$chapter · ${(fraction * 100).round()} %',
        );
      case ProgressKind.documentPage:
        // Deliberately no percentage: in a reference work it matters where you
        // land, not how far you got.
        final page = media?.numericValue?.round();
        return (null, page == null ? null : 'zuletzt Seite $page');
      case ProgressKind.playCount:
      case ProgressKind.none:
        return (null, null);
    }
  }

  static String _formatRemaining(Duration duration) {
    if (duration.inHours > 0) {
      final minutes = duration.inMinutes % 60;
      return '${duration.inHours} Std ${minutes.toString().padLeft(2, '0')} Min';
    }
    return '${duration.inMinutes} Min';
  }
}
