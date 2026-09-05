import 'package:fundus_core/fundus_core.dart';

/// How pages sit on the screen.
///
/// Kept apart from the widget so the arithmetic that decides which pages are
/// shown together can be tested without a screen — the double-page pairing in
/// particular is the sort of thing that is quietly wrong by one for a whole
/// volume.
List<List<int>> comicPageGroups(
  int pageCount, {
  required PublicationReaderLayout layout,
  required bool firstPageIsCover,
}) {
  if (pageCount <= 0) return const [];
  if (layout != PublicationReaderLayout.doublePage) {
    return [
      for (var page = 0; page < pageCount; page++) [page],
    ];
  }
  final result = <List<int>>[];
  var page = 0;
  // A cover is one sheet; pairing it with page two shifts every spread in the
  // volume by one, which is exactly how a manga stops making sense.
  if (firstPageIsCover) {
    result.add([0]);
    page = 1;
  }
  while (page < pageCount) {
    result.add([page, if (page + 1 < pageCount) page + 1]);
    page += 2;
  }
  return result;
}

/// The group a page belongs to.
int comicPageGroupIndex(List<List<int>> groups, int page) {
  final index = groups.indexWhere((group) => group.contains(page));
  return index < 0 ? 0 : index;
}

/// „Seite 7 von 180" or, for a spread, „Seiten 6–7 von 180".
String comicPageLabel(List<List<int>> groups, int page, int pageCount) {
  if (groups.isEmpty || pageCount <= 0) return '';
  final group = groups[comicPageGroupIndex(groups, page)];
  return group.length == 1
      ? 'Seite ${group.single + 1} von $pageCount'
      : 'Seiten ${group.first + 1}–${group.last + 1} von $pageCount';
}

/// Whether the layout scrolls rather than turns.
bool isContinuousLayout(PublicationReaderLayout layout) => switch (layout) {
  PublicationReaderLayout.continuousVertical ||
  PublicationReaderLayout.continuousHorizontal ||
  PublicationReaderLayout.webtoon => true,
  PublicationReaderLayout.singlePage ||
  PublicationReaderLayout.doublePage => false,
};

extension PublicationReaderLayoutPresentation on PublicationReaderLayout {
  String get label => switch (this) {
    PublicationReaderLayout.singlePage => 'Einzelseite',
    PublicationReaderLayout.doublePage => 'Doppelseite',
    PublicationReaderLayout.continuousVertical => 'Fortlaufend',
    PublicationReaderLayout.continuousHorizontal => 'Fortlaufend quer',
    PublicationReaderLayout.webtoon => 'Webtoon',
  };
}

extension PublicationPageScalePresentation on PublicationPageScale {
  String get label => switch (this) {
    PublicationPageScale.fitScreen => 'Ganze Seite',
    PublicationPageScale.fitWidth => 'Breite anpassen',
    PublicationPageScale.fitHeight => 'Höhe anpassen',
    PublicationPageScale.original => 'Originalgröße',
  };
}

extension PublicationReadingDirectionPresentation
    on PublicationReadingDirection {
  String get label => switch (this) {
    PublicationReadingDirection.leftToRight => 'Links nach rechts',
    PublicationReadingDirection.rightToLeft => 'Rechts nach links (Manga)',
  };
}

/// What a chapter list says about its own completeness.
///
/// A scraped series is missing chapter 47 more often than anyone notices, and
/// a duplicated number usually means two files for one chapter. Both are worth
/// saying out loud rather than leaving the reader to wonder why the story
/// jumps.
final class ComicChapterSequence {
  const ComicChapterSequence({
    required this.numbers,
    required this.missing,
    required this.duplicates,
  });

  /// The number read out of each title, in the order of the chapters. Null
  /// where no number could be read at all.
  final List<double?> numbers;

  /// Whole numbers between the first and the last that no chapter carries.
  final List<int> missing;

  /// Numbers carried by more than one chapter.
  final Set<double> duplicates;

  bool get hasIssues => missing.isNotEmpty || duplicates.isNotEmpty;

  /// A single line for the chapter menu, or null when nothing is amiss.
  String? get summary {
    if (!hasIssues) return null;
    final parts = <String>[];
    if (missing.isNotEmpty) {
      final shown = missing.take(6).map(formatChapterNumber).join(', ');
      final rest = missing.length > 6
          ? ' und ${missing.length - 6} weitere'
          : '';
      parts.add(
        missing.length == 1
            ? 'Kapitel $shown fehlt'
            : 'Es fehlen die Kapitel $shown$rest',
      );
    }
    if (duplicates.isNotEmpty) {
      final shown = (duplicates.toList()..sort())
          .map(formatChapterNumber)
          .join(', ');
      parts.add(
        duplicates.length == 1
            ? 'Kapitel $shown ist doppelt'
            : 'Doppelt: $shown',
      );
    }
    return parts.join(' · ');
  }
}

final _chapterNumberPattern = RegExp(
  r'(?:kapitel|chapter|ch\.?|band|volume|vol\.?)\s*[-_:#]*\s*(\d+(?:[.,]\d+)?)',
  caseSensitive: false,
);

/// Reads the chapter numbers out of a list of titles and reports the gaps.
ComicChapterSequence comicChapterSequence(List<String> titles) {
  final numbers = <double?>[
    for (final title in titles)
      double.tryParse(
        (_chapterNumberPattern.firstMatch(title)?.group(1) ?? '').replaceAll(
          ',',
          '.',
        ),
      ),
  ];
  final counts = <double, int>{};
  for (final number in numbers.nonNulls) {
    counts.update(number, (count) => count + 1, ifAbsent: () => 1);
  }
  final duplicates = counts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toSet();
  final wholeNumbers = counts.keys
      .where((number) => number == number.roundToDouble())
      .map((number) => number.toInt())
      .toSet();
  final missing = <int>[];
  if (wholeNumbers.length >= 2) {
    final sorted = wholeNumbers.toList()..sort();
    // A stray „Band 2024" in a title would otherwise report two thousand
    // missing chapters.
    if (sorted.last - sorted.first <= 2000) {
      for (var number = sorted.first; number <= sorted.last; number++) {
        if (!wholeNumbers.contains(number)) missing.add(number);
      }
    }
  }
  return ComicChapterSequence(
    numbers: List.unmodifiable(numbers),
    missing: List.unmodifiable(missing),
    duplicates: Set.unmodifiable(duplicates),
  );
}

/// „7" rather than „7.0", but „7.5" where that is what it says.
String formatChapterNumber(num number) => number == number.roundToDouble()
    ? number.toInt().toString()
    : number.toString();

/// The chapter number a title carries, if it carries one.
double? comicChapterNumber(String title) => double.tryParse(
  (_chapterNumberPattern.firstMatch(title)?.group(1) ?? '').replaceAll(
    ',',
    '.',
  ),
);

/// What a layout is called where somebody has to choose one.
String comicLayoutLabel(PublicationReaderLayout layout) => switch (layout) {
  PublicationReaderLayout.singlePage => 'Einzelseite',
  PublicationReaderLayout.doublePage => 'Doppelseite',
  PublicationReaderLayout.continuousVertical => 'Fortlaufend',
  PublicationReaderLayout.continuousHorizontal => 'Waagerecht',
  PublicationReaderLayout.webtoon => 'Longstrip',
};

/// The next way of reading, in the order somebody would try them.
///
/// A button that cycles rather than a menu: there are five, they are all
/// worth trying on an unfamiliar work, and the wrong one is one tap from the
/// right one.
PublicationReaderLayout nextComicLayout(PublicationReaderLayout layout) =>
    switch (layout) {
      PublicationReaderLayout.singlePage => PublicationReaderLayout.doublePage,
      PublicationReaderLayout.doublePage =>
        PublicationReaderLayout.continuousVertical,
      PublicationReaderLayout.continuousVertical =>
        PublicationReaderLayout.webtoon,
      PublicationReaderLayout.webtoon =>
        PublicationReaderLayout.continuousHorizontal,
      PublicationReaderLayout.continuousHorizontal =>
        PublicationReaderLayout.singlePage,
    };
