import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';

/// Mehrere Schnellfilter zugleich.
///
/// Chips lesen sich als „und außerdem": jeder schränkt weiter ein.
void main() {
  test('Mengen werden vereinigt', () {
    const shonen = LibraryWorkQuery(tags: {'Shōnen'});
    const webtoon = LibraryWorkQuery(tags: {'Webtoon'});

    expect(shonen.merge(webtoon).tags, {'Shōnen', 'Webtoon'});
  });

  test('ein eingeschalteter Schalter bleibt an', () {
    const offline = LibraryWorkQuery(offlineOnly: true);
    const anything = LibraryWorkQuery();

    expect(offline.merge(anything).offlineOnly, isTrue);
    expect(anything.merge(offline).offlineOnly, isTrue);
  });

  test('wo nur einer stehen kann, gewinnt der spätere', () {
    const byTitle = LibraryWorkQuery(sort: LibraryWorkSort.title);
    const byProgress = LibraryWorkQuery(sort: LibraryWorkSort.progress);

    expect(byTitle.merge(byProgress).sort, LibraryWorkSort.progress);
    // Aber „egal" überschreibt keine Wahl.
    expect(byTitle.merge(const LibraryWorkQuery()).sort, LibraryWorkSort.title);
  });

  test('ein leerer Text löscht keinen gesetzten', () {
    const search = LibraryWorkQuery(text: 'Klingenwind');

    expect(search.merge(const LibraryWorkQuery()).text, 'Klingenwind');
  });
}
