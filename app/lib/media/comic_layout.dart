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
