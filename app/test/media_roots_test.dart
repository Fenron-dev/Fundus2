import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';

Future<void> writeFile(String path, {int bytes = 64}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List.filled(bytes, 7));
}

void main() {
  late Directory root;
  late LibraryController library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-roots-');
    library = LibraryController();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  test('die üblichen Ordnernamen werden erkannt', () async {
    await writeFile('${root.path}/Hörbücher/Karl May/Winnetou/01.mp3');
    await writeFile('${root.path}/Manga/Klingenwind/Band 01.cbz');
    await writeFile('${root.path}/Light Novels/Glasmeer/Band 01.epub');
    await writeFile('${root.path}/Anime/Kaltes Orbit/S01E01.mkv');

    await library.open(root, createIfMissing: true);
    await library.scan();

    final areas = library.works
        .map((work) => work.mediaType?.id ?? 'unbekannt')
        .toSet();

    expect(areas, contains(MediaTypes.audiobook.id));
    expect(areas, contains(MediaTypes.manga.id));
    // Der Ordner hieß früher „Webnovels" und heißt jetzt „Light Novels".
    expect(areas, contains(MediaTypes.novels.id));
    expect(areas, contains(MediaTypes.anime.id));
    expect(areas, isNot(contains('unbekannt')));
  });

  test('ein unbekannter Ordner wird gemeldet statt übergangen', () async {
    await writeFile('${root.path}/Meine Sachen/Irgendwas/datei.epub');

    await library.open(root, createIfMissing: true);
    await library.scan();

    expect(library.works, isEmpty);
    expect(library.unassignedFolders.keys, contains('Meine Sachen'));
  });

  test('eine Zuordnung wird gespeichert und liest die Werke ein', () async {
    await writeFile('${root.path}/Meine Sachen/Glasmeer/Band 01.epub');

    await library.open(root, createIfMissing: true);
    await library.scan();
    expect(library.works, isEmpty);

    await library.assignFolder(
      'Meine Sachen',
      MediaTypes.books.configurationKind!,
    );

    expect(library.works, isNotEmpty);
    expect(library.works.first.mediaType?.id, MediaTypes.books.id);
    expect(library.unassignedFolders, isEmpty);

    // Die Zuordnung gehört der Bibliothek, nicht dem Gerät.
    final config = File('${root.path}/.library/config.yaml');
    expect(await config.readAsString(), contains('Meine Sachen'));
  });

  test(
    'die Verwaltungsordner der Bibliothek gelten nicht als unbekannt',
    () async {
      await writeFile('${root.path}/Hörbücher/Karl May/Winnetou/01.mp3');

      await library.open(root, createIfMissing: true);
      await library.scan();

      expect(library.unassignedFolders.keys, isNot(contains('.library')));
      expect(library.unassignedFolders.keys, isNot(contains('_fundus')));
    },
  );
}
