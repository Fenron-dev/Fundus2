import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Podcast-Kapitel stecken in den ID3-Rahmen der MP3 selbst.
///
/// Manche Sendungen legen auf jede Folge ein Bild je Kapitel — bei „Stay
/// Forever" der Bildschirm des Spiels, über das gerade geredet wird. Das ist
/// Inhalt, nicht Schmuck.
void main() {
  test('CHAP-Rahmen werden mit Titel und Bild gelesen', () async {
    final root = await Directory.systemTemp.createTemp('fundus-chap-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Folge 1.mp3');
    await file.writeAsBytes(
      _mp3WithChapters([
        (id: 'ch1', start: 0, title: 'Vorspann', image: false),
        (id: 'ch2', start: 90000, title: 'Das Spiel', image: true),
      ]),
    );

    final chapters = await const EmbeddedCoverExtractor().extractChapters(file);

    expect(chapters, hasLength(2));
    expect(chapters.first.title, 'Vorspann');
    expect(chapters.first.position, Duration.zero);
    expect(chapters.first.image, isNull);
    expect(chapters[1].title, 'Das Spiel');
    expect(chapters[1].position, const Duration(minutes: 1, seconds: 30));
    expect(chapters[1].image, isNotNull);
    expect(chapters[1].image!.extension, 'jpg');
  });

  test('die Bilder einer Folge landen als Dateien in der Bibliothek', () async {
    final root = await Directory.systemTemp.createTemp('fundus-chap-lib-');
    addTearDown(() => root.delete(recursive: true));
    final show = Directory('${root.path}/Podcasts/Stay Forever')
      ..createSync(recursive: true);
    await File('${show.path}/SF 100.mp3').writeAsBytes(
      _mp3WithChapters([
        (id: 'ch1', start: 0, title: 'Begrüßung', image: false),
        (id: 'ch2', start: 90000, title: 'Das Spiel', image: true),
      ]),
    );

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    final fileId = library.playbackTracks(work.id).single.fileId;

    final chapters = await library.trackChapters(work.id, fileId);

    expect(chapters, hasLength(2));
    expect(chapters.first.imagePath, isNull);
    // Im Podcast steckt das Bild in der Datei; hier liegt es, wo etwas es
    // zeichnen kann.
    final picture = chapters[1].imagePath;
    expect(picture, isNotNull);
    expect(File(picture!).existsSync(), isTrue);

    // Ein zweiter Aufruf schreibt es nicht noch einmal.
    final again = await library.trackChapters(work.id, fileId);
    expect(again[1].imagePath, picture);
  });

  test('eine MP3 ohne Kapitel liefert eine leere Liste', () async {
    final root = await Directory.systemTemp.createTemp('fundus-chap-none-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Ohne.mp3');
    await file.writeAsBytes(_mp3WithChapters(const []));

    expect(await const EmbeddedCoverExtractor().extractChapters(file), isEmpty);
  });

  test('die Kapitel kommen in zeitlicher Reihenfolge', () async {
    final root = await Directory.systemTemp.createTemp('fundus-chap-order-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Durcheinander.mp3');
    await file.writeAsBytes(
      _mp3WithChapters([
        (id: 'b', start: 120000, title: 'Zweitens', image: false),
        (id: 'a', start: 0, title: 'Erstens', image: false),
      ]),
    );

    final chapters = await const EmbeddedCoverExtractor().extractChapters(file);

    expect(chapters.map((chapter) => chapter.title), ['Erstens', 'Zweitens']);
  });
}

/// Ein winziges JPEG — nur die Signatur, mehr sucht der Leser nicht.
final _jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0, 0]);

List<int> _mp3WithChapters(
  List<({String id, int start, String title, bool image})> chapters,
) {
  final frames = <int>[];
  for (final chapter in chapters) {
    frames.addAll(_frame('CHAP', _chapPayload(chapter)));
  }
  return [
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    ..._synchsafe(frames.length),
    ...frames,
  ];
}

List<int> _chapPayload(
  ({String id, int start, String title, bool image}) chapter,
) {
  final subframes = <int>[
    ..._frame('TIT2', [0, ...latin1.encode(chapter.title)]),
    if (chapter.image)
      ..._frame('APIC', [0, ...ascii.encode('image/jpeg'), 0, 3, 0, ..._jpeg]),
  ];
  return [
    ...latin1.encode(chapter.id),
    0,
    ..._uint32(chapter.start),
    ..._uint32(chapter.start + 60000),
    ..._uint32(0xffffffff),
    ..._uint32(0xffffffff),
    ...subframes,
  ];
}

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
