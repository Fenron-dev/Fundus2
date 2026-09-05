import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Welche Staffel und welche Folge — steht im Dateinamen, sonst nirgends.
void main() {
  test('S01E02 in den üblichen Schreibweisen', () {
    for (final name in [
      'S01E02 - Together With Senpai.mkv',
      's1e2.mkv',
      'Serie.S01.E02.1080p.mkv',
      'Serie S01 E02.mkv',
    ]) {
      final number = episodeNumberOf(name);
      expect(number.season, 1, reason: name);
      expect(number.episode, 2, reason: name);
    }
  });

  test('1x02 zählt auch', () {
    final number = episodeNumberOf('Serie - 1x02.mkv');

    expect(number.season, 1);
    expect(number.episode, 2);
  });

  test('sagt der Name nichts, antwortet der Ordner', () {
    final number = episodeNumberOf('Staffel 2/Folge 04 - Rückkanal.mkv');

    expect(number.season, 2);
    expect(number.episode, 4);
  });

  test('season 3 auf Englisch', () {
    expect(episodeNumberOf('Season 3/Episode 11.mkv').season, 3);
  });

  test('der Name schlägt den Ordner', () {
    // Ein Sonderfolgen-Ordner mit einer regulären Folge darin: der Name ist
    // die genauere Aussage.
    final number = episodeNumberOf('Staffel 1/S02E05.mkv');

    expect(number.season, 2);
    expect(number.episode, 5);
  });

  test('ein Film hat keine Nummer und bekommt keine erfunden', () {
    expect(episodeNumberOf('About Time.mkv').isEmpty, isTrue);
    expect(episodeNumberOf('').isEmpty, isTrue);
  });

  test('eine Jahreszahl im Titel wird nicht zur Staffel', () {
    expect(episodeNumberOf('Doku 2024.mkv').isEmpty, isTrue);
  });
}
