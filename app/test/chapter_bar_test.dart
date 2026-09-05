import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/comic_layout.dart';
import 'package:fundus_core/fundus_core.dart';

/// Was die Leiste unten anzeigt und umschaltet.
void main() {
  test('die Kapitelnummer wird aus dem Titel gelesen', () {
    expect(comicChapterNumber('Kapitel 41.cbz'), 41);
    expect(comicChapterNumber('Chapter 7.5'), 7.5);
    expect(comicChapterNumber('Prolog'), isNull);
  });

  test('die Leserichtung geht im Kreis', () {
    var layout = PublicationReaderLayout.singlePage;
    final seen = <PublicationReaderLayout>{};
    for (var step = 0; step < PublicationReaderLayout.values.length; step++) {
      seen.add(layout);
      layout = nextComicLayout(layout);
    }

    // Jede Art kommt genau einmal vor, und am Ende ist man wieder am Anfang.
    expect(seen, hasLength(PublicationReaderLayout.values.length));
    expect(layout, PublicationReaderLayout.singlePage);
  });

  test('jede Art hat einen Namen', () {
    for (final layout in PublicationReaderLayout.values) {
      expect(comicLayoutLabel(layout), isNotEmpty);
    }
    expect(comicLayoutLabel(PublicationReaderLayout.webtoon), 'Longstrip');
  });
}
