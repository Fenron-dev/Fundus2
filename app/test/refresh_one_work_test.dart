import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';

/// Ein Werk zu öffnen liest nicht die ganze Bibliothek neu.
///
/// Das Protokoll zeigte es: die eigentliche Arbeit war nach 330 ms fertig,
/// das Öffnen dauerte 7,7 Sekunden. Dazwischen lag das Neuladen von zwölf-
/// tausend Werken, um einen Fortschrittsbalken zu bewegen.
void main() {
  late Directory root;
  late LibraryController library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-refresh-');
    for (final title in ['Eins', 'Zwei', 'Drei']) {
      final folder = Directory('${root.path}/Hörbücher/Autor/$title')
        ..createSync(recursive: true);
      await File(
        '${folder.path}/01 - Kapitel.mp3',
      ).writeAsBytes(List.filled(64, 1));
    }
    library = LibraryController();
    await library.open(root, createIfMissing: true);
    await library.scan();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  test('der Stand eines Werks kommt an, die Liste bleibt dieselbe', () {
    expect(library.works, hasLength(3));
    final before = library.works;
    final work = library.works.firstWhere((entry) => entry.title == 'Zwei');
    final others = library.works
        .where((entry) => entry.id != work.id)
        .map((entry) => entry.id)
        .toList();

    library.library!.saveProgress(
      workId: work.id,
      fileId: library.library!.playbackTracks(work.id).single.fileId,
      position: const Duration(minutes: 12),
      duration: const Duration(hours: 1),
      deviceId: 'test',
    );
    library.refreshWork(work.id);

    final after = library.works.firstWhere((entry) => entry.id == work.id);
    expect(after.hasProgress, isTrue);
    expect(library.works, hasLength(3));
    expect(
      library.works.where((entry) => entry.id != work.id).map((e) => e.id),
      others,
      reason: 'die Reihenfolge der übrigen bleibt, wie sie war',
    );
    expect(
      identical(before, library.works),
      isFalse,
      reason: 'die Liste ist neu, ihr Inhalt aber bis auf ein Werk derselbe',
    );
  });

  test('die Zählung pro Medienart geht mit', () async {
    final work = library.works.first;
    expect(library.worksPerMediaType['audiobook'], 3);

    await library.library!.updateWorkKind(workId: work.id, kind: 'movie');
    library.refreshWork(work.id);

    expect(library.worksPerMediaType['audiobook'], 2);
    expect(library.worksPerMediaType['movie'], 1);
  });

  test('ein Werk, das die Sperre verbirgt, fällt aus der Liste', () {
    final work = library.works.first;
    library.hides = (entry) => entry.id == work.id;

    library.refreshWork(work.id);

    expect(library.works, hasLength(2));
    expect(library.works.any((entry) => entry.id == work.id), isFalse);
  });
}
