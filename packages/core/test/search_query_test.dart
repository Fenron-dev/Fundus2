import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeSearchQuery', () {
    // Gemessen am 13.09.2026 gegen AniList: jede rohe Fassung lieferte null
    // Treffer, jede bereinigte einen. Die Tabelle ist der Grund für diese
    // Funktion und steht deshalb als Test.
    const cases = {
      'Solo Leveling': 'Solo Leveling',
      'Solo Leveling (2018)': 'Solo Leveling',
      'Solo Leveling v01': 'Solo Leveling',
      'Solo_Leveling_Vol_1': 'Solo Leveling',
      '[Asura] Solo Leveling - Chapter 001 (2018) (Digital)': 'Solo Leveling',
      'Attack on Titan S04E12': 'Attack on Titan',
      'Tales of Demons and Gods - Kapitel 1-50': 'Tales of Demons and Gods',
      'Berserk.cbz': 'Berserk',
    };
    cases.forEach((raw, expected) {
      test('„$raw" wird zu „$expected"', () {
        expect(normalizeSearchQuery(raw), expected);
      });
    });

    test('eine Zahl am Ende bleibt zunächst stehen', () {
      // „Blade Runner 2049" traegt die Zahl im Titel, „Berserk 01" nicht.
      // Das zu unterscheiden ist Sache der Leiter, nicht der Bereinigung.
      expect(normalizeSearchQuery('Blade Runner 2049'), 'Blade Runner 2049');
      expect(normalizeSearchQuery('Berserk 01'), 'Berserk 01');
    });

    test('ein Titel, der nur aus einer Zahl besteht, überlebt', () {
      expect(normalizeSearchQuery('86'), '86');
      expect(searchQueryLadder('86'), ['86']);
    });

    test('ein sauberer Titel wird nicht angefasst', () {
      expect(
        normalizeSearchQuery('Die Säulen der Erde'),
        'Die Säulen der Erde',
      );
    });
  });

  group('searchQueryLadder', () {
    test('fragt zuerst vollständig, dann kürzer', () {
      expect(searchQueryLadder('Blade Runner 2049'), [
        'Blade Runner 2049',
        'Blade Runner',
      ]);
    });

    test('ein Untertitel hinter Gedankenstrich wird zur zweiten Stufe', () {
      // Gemessen: „Frieren - Beyond Journeys End" liefert null Treffer,
      // „Frieren" zwei — obwohl der lange Titel korrekt ist.
      expect(
        searchQueryLadder('Frieren - Beyond Journeys End'),
        containsAllInOrder(['Frieren - Beyond Journeys End', 'Frieren']),
      );
    });

    test('kürzt zuletzt auf die ersten Wörter', () {
      expect(
        searchQueryLadder('One Piece Colored Edition'),
        containsAllInOrder(['One Piece Colored Edition', 'One Piece']),
      );
    });

    test('liefert keine Dubletten und nichts Leeres', () {
      final steps = searchQueryLadder('[Gruppe] Naruto Vol. 3 (2002).cbz');
      expect(steps, isNotEmpty);
      expect(steps.toSet(), hasLength(steps.length));
      expect(steps.any((step) => step.trim().isEmpty), isFalse);
      expect(steps.first, 'Naruto');
    });

    test('eine leere Anfrage ergibt keine Stufen', () {
      expect(searchQueryLadder('   '), isEmpty);
      expect(searchQueryLadder('[nur] (klammern)'), isEmpty);
    });
  });
}
