import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Kapitelbilder in einer Podcast-Folge.
///
/// Manche Sendungen legen auf jedes Kapitel ein Bild — bei „Stay Forever" der
/// Bildschirm des Spiels, über das gerade geredet wird. Das ist Inhalt.
void main() {
  late Directory root;
  late LibraryController library;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-podcast-chap-');
    final show = Directory('${root.path}/Podcasts/Stay Forever')
      ..createSync(recursive: true);
    await File('${show.path}/SF 100.mp3').writeAsBytes(
      _mp3WithChapters([
        (id: 'ch1', start: 0, title: 'Begrüßung', image: false),
        (id: 'ch2', start: 90000, title: 'Das Spiel', image: true),
      ]),
    );
    library = LibraryController();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('das Bild des laufenden Kapitels steht im Player', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();
    await player.open(library.library!, library.works.single);
    // Die Kapitel werden nach dem Start gelesen, damit niemand auf ein Bild
    // wartet — hier wird genau darauf gewartet.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(player.trackChapters, hasLength(2));
    // Am Anfang: kein Bild, aber ein Name.
    expect(player.chapterTitle, 'Begrüßung');
    expect(player.chapterImagePath, isNull);

    engine.emitPosition(const Duration(minutes: 2));
    await Future<void>.delayed(Duration.zero);

    expect(player.chapterTitle, 'Das Spiel');
    expect(player.chapterImagePath, isNotNull);
    expect(File(player.chapterImagePath!).existsSync(), isTrue);
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
