import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/reader_controller.dart';

/// Was der Leser über die Maße einer Seite weiß.
///
/// Eine Webtoon-Seite ist ein Streifen, manchmal fünfmal so hoch wie breit.
/// Ein Platzhalter im Format 2:3 lässt den Streifen wachsen, sobald das Bild
/// ankommt — und alles darunter rutscht unter dem Daumen weg.
void main() {
  test('eine gemessene Seite behält ihr Maß', () {
    final reader = ReaderController();
    addTearDown(reader.dispose);

    expect(reader.aspectOf(3), isNull);
    reader.rememberAspect(3, 0.2);

    expect(reader.aspectOf(3), 0.2);
  });

  test('ungemessene Seiten borgen sich das Maß der gemessenen', () {
    final reader = ReaderController();
    addTearDown(reader.dispose);

    reader.rememberAspect(0, 0.2);

    // Innerhalb eines Kapitels sind die Seiten fast immer gleich geschnitten.
    expect(reader.aspectOf(7), 0.2);
  });

  test('eine einzelne Bannerseite verstellt nicht den Rest', () {
    final reader = ReaderController();
    addTearDown(reader.dispose);

    reader.rememberAspect(0, 0.7);
    reader.rememberAspect(1, 0.71);

    expect(reader.aspectOf(9), closeTo(0.7, 0.05));
  });

  test('unsinnige Maße werden nicht übernommen', () {
    final reader = ReaderController();
    addTearDown(reader.dispose);

    reader.rememberAspect(0, 0);
    reader.rememberAspect(1, double.infinity);

    expect(reader.aspectOf(0), isNull);
  });
}
