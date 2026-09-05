import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Which of two positions is further along.
///
/// A page number alone cannot say: a manga is a folder of chapters, each
/// numbered from page one, so page 12 of chapter one looks bigger than page 1
/// of chapter two while being an hour behind it.
void main() {
  MediaPosition page(String fileId, double number) => MediaPosition(
    kind: MediaPositionKind.page,
    numericValue: number,
    fileId: fileId,
  );

  const order = ['chapter-1', 'chapter-2', 'chapter-3'];

  test('das spätere Kapitel gewinnt, auch mit kleinerer Seitenzahl', () {
    expect(
      comparePositions(
        page('chapter-2', 1),
        page('chapter-1', 12),
        fileOrder: order,
      ),
      greaterThan(0),
    );
  });

  test('im selben Kapitel entscheidet die Seite', () {
    expect(
      comparePositions(
        page('chapter-2', 3),
        page('chapter-2', 9),
        fileOrder: order,
      ),
      lessThan(0),
    );
  });

  test(
    'auf derselben Seite entscheidet, wie weit man heruntergescrollt ist',
    () {
      const top = MediaPosition(
        kind: MediaPositionKind.page,
        numericValue: 3,
        fileId: 'chapter-2',
        scrollOffset: 0.1,
      );
      const further = MediaPosition(
        kind: MediaPositionKind.page,
        numericValue: 3,
        fileId: 'chapter-2',
        scrollOffset: 0.8,
      );

      expect(comparePositions(further, top, fileOrder: order), greaterThan(0));
      expect(comparePositions(top, top, fileOrder: order), 0);
    },
  );

  test('eine Zeitangabe in einer Datei vergleicht sich wie bisher', () {
    const early = MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: 120,
      fileId: 'film',
    );
    const late = MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: 4200,
      fileId: 'film',
    );

    expect(comparePositions(late, early, fileOrder: ['film']), greaterThan(0));
  });

  test('eine unbekannte Datei gilt als die erste, nicht als die letzte', () {
    // Sonst würde ein Stand aus einem Kapitel, das dieses Gerät noch nicht
    // kennt, jeden anderen schlagen.
    expect(
      comparePositions(
        page('kennt-hier-niemand', 1),
        page('chapter-3', 5),
        fileOrder: order,
      ),
      lessThan(0),
    );
  });
}
