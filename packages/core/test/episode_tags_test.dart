import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Was eine heruntergeladene Folge selbst über sich sagt.
///
/// Ein Ordner enthält oft mehrere Sendungen desselben Hauses, und ein Feed
/// kennt immer nur seine eigene. Der Text steht aber ohnehin in der Datei —
/// jeder Downloader schreibt ihn in die Tags.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-tags-');
  });

  tearDown(() => root.delete(recursive: true));

  test('Kommentar und Datum werden zur Folgenbeschreibung', () async {
    final file = File('${root.path}/folge.mp3');
    await file.writeAsBytes(
      _mp3([
        _text('TIT2', 'Auf ein Bier #564'),
        _comment('Tolle Dinge, die wir nicht toll finden.'),
        _text('TDRL', '2026-01-11'),
      ]),
    );

    final tags = await const EmbeddedCoverExtractor().extractMetadata(file);

    expect(tags.title, 'Auf ein Bier #564');
    expect(tags.description, 'Tolle Dinge, die wir nicht toll finden.');
    expect(tags.publishedAt, DateTime.utc(2026, 1, 11));
  });

  test(
    'die eigens für Podcasts gedachte Beschreibung schlägt sie nicht',
    () async {
      final file = File('${root.path}/lang.mp3');
      await file.writeAsBytes(
        _mp3([
          _text('TDES', '<p>Erster Absatz.</p><p>Zweiter Absatz.</p>'),
          _comment('Nur ein Kommentar.'),
        ]),
      );

      final tags = await const EmbeddedCoverExtractor().extractMetadata(file);

      // HTML wird zu Absätzen, nicht zu einer Wand aus spitzen Klammern.
      expect(tags.description, 'Erster Absatz.\n\nZweiter Absatz.');
    },
  );

  test('ein Jahr allein ist auch ein Datum', () async {
    final file = File('${root.path}/jahr.mp3');
    await file.writeAsBytes(_mp3([_text('TYER', '2019')]));

    final tags = await const EmbeddedCoverExtractor().extractMetadata(file);

    expect(tags.publishedAt, DateTime.utc(2019));
  });

  test('ohne Text bleibt es leer, statt etwas zu erfinden', () async {
    final file = File('${root.path}/leer.mp3');
    await file.writeAsBytes(_mp3([_text('TIT2', 'Ohne alles')]));

    final tags = await const EmbeddedCoverExtractor().extractMetadata(file);

    expect(tags.description, isNull);
    expect(tags.publishedAt, isNull);
  });
}

List<int> _mp3(List<List<int>> frames) {
  final body = [for (final frame in frames) ...frame];
  return [...ascii.encode('ID3'), 3, 0, 0, ..._synchsafe(body.length), ...body];
}

List<int> _text(String id, String value) =>
    _frame(id, [0, ...latin1.encode(value)]);

/// Ein `COMM`-Rahmen: Kodierung, Sprache, kurze Überschrift, dann der Text.
List<int> _comment(String value) => _frame('COMM', [
  0,
  ...ascii.encode('deu'),
  ...latin1.encode('Beschreibung'),
  0,
  ...latin1.encode(value),
]);

List<int> _frame(String id, List<int> payload) => [
  ...ascii.encode(id),
  ..._uint32(payload.length),
  0,
  0,
  ...payload,
];

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _synchsafe(int value) => [
  (value >> 21) & 0x7f,
  (value >> 14) & 0x7f,
  (value >> 7) & 0x7f,
  value & 0x7f,
];
