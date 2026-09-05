import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/features/work/download_choice_sheet.dart';

/// Welche Kapitel mitkommen.
void main() {
  test('ein Bereich zählt ab eins', () {
    expect(chapterRange(total: 10, from: 1, to: 3), {0, 1, 2});
  });

  test('verdrehte Grenzen werden gelesen, wie sie gemeint sind', () {
    expect(chapterRange(total: 10, from: 5, to: 2), {1, 2, 3, 4});
  });

  test('über das Ende hinaus wird abgeschnitten', () {
    expect(chapterRange(total: 3, from: 2, to: 99), {1, 2});
  });

  test('ein Werk ohne Kapitel hat nichts zu wählen', () {
    expect(chapterRange(total: 0, from: 1, to: 5), isEmpty);
  });
}
