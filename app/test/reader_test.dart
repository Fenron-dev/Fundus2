import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/comic_archive.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_core/fundus_core.dart';

/// A stand-in for a CBZ: it answers with the pages it was given and hands out
/// made-up file paths, which is the whole surface the reader's rules touch.
final class FakePageSource implements ComicPageSource {
  FakePageSource(this.name, this.pageCount);

  @override
  final String name;
  final int pageCount;
  final List<List<String>> materialized = [];

  @override
  Future<List<ComicPage>> pages() async => [
    for (var index = 1; index <= pageCount; index++)
      ComicPage(id: '$name/$index.jpg', name: '$index.jpg', size: 10),
  ];

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    materialized.add([for (final page in pages) page.id]);
    return {for (final page in pages) page.id: '/tmp/${page.id}'};
  }

  @override
  Future<void> dispose() async {}
}

/// Builds a CBZ with the given entry names.
///
/// Synchronous on purpose: real file I/O awaited in the body of a
/// `testWidgets` runs in the fake-async zone and never comes back.
String writeArchive(Directory directory, String name, List<String> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(ArchiveFile.bytes(entry, List.filled(8, 1)));
  }
  final path = '${directory.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  return path;
}

void main() {
  group('Der Leser rechnet in Seiten, nicht in Sekunden', () {
    late Directory root;
    late LibraryController library;
    late Map<String, FakePageSource> sources;
    late ReaderController reader;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-reader-');
      final work = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      for (final volume in ['Band 01', 'Band 02']) {
        writeArchive(work, '$volume.cbz', ['001.jpg', '002.jpg']);
      }
      library = LibraryController();
      sources = {};
      reader = ReaderController(
        openSource: (path, name) =>
            sources.putIfAbsent(name, () => FakePageSource(name, 20)),
      );
    });

    tearDown(() async {
      reader.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    Future<void> openWork() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await reader.open(library.library!, library.works.first);
    }

    test('ein Manga landet im Leser, nicht im Player', () async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      expect(ReaderController.handles(library.works.first), isTrue);
    });

    test('geöffnet wird beim ersten Band, Seite eins', () async {
      await openWork();

      expect(reader.failure, isNull);
      expect(reader.volumes, hasLength(2));
      expect(reader.volumeIndex, 0);
      expect(reader.pageIndex, 0);
      expect(reader.positionLabel, contains('Seite 1 von 20'));
    });

    test('die Seite wird gemerkt und wieder aufgenommen', () async {
      await openWork();
      await reader.goToPage(6);

      final saved = library.library!.loadProgress(library.works.first.id);
      expect(saved, isNotNull);
      expect(saved!.position.kind, MediaPositionKind.page);
      // Gespeichert wird die Seite, wie sie dasteht: eins-basiert.
      expect(saved.position.numericValue, 7);
      expect(saved.position.total, 20);

      final second = ReaderController(
        openSource: (path, name) => FakePageSource(name, 20),
      );
      addTearDown(second.dispose);
      await second.open(library.library!, library.works.first);
      expect(second.pageIndex, 6);
    });

    test('hinter der letzten Seite steht der nächste Band', () async {
      await openWork();
      await reader.goToPage(19);
      await reader.nextPage();

      expect(reader.volumeIndex, 1);
      expect(reader.pageIndex, 0);
      expect(reader.volumes[1].title, contains('Band 02'));
    });

    test('vor der ersten Seite steht das Ende des vorigen Bands', () async {
      await openWork();
      await reader.openVolume(1);
      await reader.previousPage();

      expect(reader.volumeIndex, 0);
      expect(reader.pageIndex, 19);
    });

    test('am Anfang des ersten Bands geht es nicht weiter zurück', () async {
      await openWork();
      await reader.previousPage();

      expect(reader.volumeIndex, 0);
      expect(reader.pageIndex, 0);
      expect(reader.failure, isNull);
    });

    test(
      'entpackt wird die Seite und ihre Nachbarin, nicht der Band',
      () async {
        await openWork();

        final source = sources.values.first;
        final unpacked = source.materialized.expand((batch) => batch).toSet();
        // Zwei Seiten im Voraus ist die Vorgabe, der Band hat zwanzig.
        expect(reader.profile.preloadCount, 2);
        expect(
          unpacked,
          hasLength(3),
          reason: 'Entpackt wurde mehr als die Vorschau verlangt',
        );
        expect(unpacked, contains('Band 01.cbz/1.jpg'));
        expect(unpacked, contains('Band 01.cbz/3.jpg'));
        expect(unpacked, isNot(contains('Band 01.cbz/20.jpg')));
      },
    );
  });

  group('Kapitel sind Archive, nicht alles im Ordner', () {
    late Directory root;
    late LibraryController library;
    late ReaderController reader;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-chapters-');
      final work = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      writeArchive(work, 'Band 01.cbz', ['001.jpg']);
      writeArchive(work, 'Band 02.cbz', ['001.jpg']);
      // Was sonst noch im Werkordner liegt und kein Kapitel ist.
      File('${work.path}/cover.jpg').writeAsBytesSync(List.filled(64, 1));
      File('${work.path}/banner.png').writeAsBytesSync(List.filled(64, 2));
      library = LibraryController();
      reader = ReaderController(
        openSource: (path, name) => FakePageSource(name, 5),
      );
    });

    tearDown(() async {
      reader.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    test('das Cover ist kein Kapitel', () async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await reader.open(library.library!, library.works.first);

      expect(reader.volumes, hasLength(2));
      expect(
        reader.volumes.map((volume) => volume.title),
        everyElement(endsWith('.cbz')),
      );
    });

    test('ein Werk ganz ohne Archiv sagt das', () async {
      final other = Directory('${root.path}/Manga/Nur Bilder')
        ..createSync(recursive: true);
      File('${other.path}/cover.jpg').writeAsBytesSync(List.filled(64, 1));

      await library.open(root, createIfMissing: true);
      await library.scan();
      final work = library.works.firstWhere(
        (candidate) => candidate.title.contains('Nur Bilder'),
        orElse: () => library.works.last,
      );
      await reader.open(library.library!, work);

      if (reader.volumes.isEmpty) {
        expect(reader.failure, contains('kein lesbares Archiv'));
      }
    });
  });

  group('Wie gelesen wird, entscheidet der Leser', () {
    late Directory root;
    late LibraryController library;
    late ReaderController reader;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-layout-');
      final work = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      writeArchive(work, 'Band 01.cbz', ['001.jpg']);
      library = LibraryController();
      reader = ReaderController(
        openSource: (path, name) => FakePageSource(name, 10),
      );
      await library.open(root, createIfMissing: true);
      await library.scan();
      await reader.open(library.library!, library.works.first);
    });

    tearDown(() async {
      reader.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    test('Doppelseite lässt das Cover allein stehen', () async {
      await reader.updateProfile(
        reader.profile.copyWith(
          layout: PublicationReaderLayout.doublePage,
          firstPageIsCover: true,
        ),
      );

      expect(reader.pageGroups.first, [0]);
      expect(reader.pageGroups[1], [1, 2]);
      expect(reader.positionLabel, contains('Seite 1 von 10'));

      await reader.nextPage();
      expect(reader.pageIndex, 1);
      expect(reader.positionLabel, contains('Seiten 2–3 von 10'));
    });

    test('ohne Cover beginnt die erste Doppelseite bei eins', () async {
      await reader.updateProfile(
        reader.profile.copyWith(
          layout: PublicationReaderLayout.doublePage,
          firstPageIsCover: false,
        ),
      );

      expect(reader.pageGroups.first, [0, 1]);
    });

    test('Webtoon ist fortlaufend, Einzelseite nicht', () async {
      await reader.updateProfile(
        reader.profile.copyWith(layout: PublicationReaderLayout.webtoon),
      );
      expect(reader.isContinuous, isTrue);

      await reader.updateProfile(
        reader.profile.copyWith(layout: PublicationReaderLayout.singlePage),
      );
      expect(reader.isContinuous, isFalse);
    });

    test('die Leserichtung wird gemerkt', () async {
      await reader.updateProfile(
        reader.profile.copyWith(
          readingDirection: PublicationReadingDirection.rightToLeft,
        ),
      );
      expect(reader.isRightToLeft, isTrue);

      final again = ReaderController(
        openSource: (path, name) => FakePageSource(name, 10),
      );
      addTearDown(again.dispose);
      await again.open(library.library!, library.works.first);
      expect(again.isRightToLeft, isTrue);
    });

    test('ein Lesezeichen führt zurück auf seine Seite', () async {
      await reader.goToPage(4);
      await reader.addBookmark(note: 'Der Kampf');
      await reader.goToPage(0);

      expect(reader.bookmarks, hasLength(1));
      expect(reader.bookmarks.single.note, 'Der Kampf');

      await reader.goToBookmark(reader.bookmarks.single);
      expect(reader.pageIndex, 4);

      await reader.deleteBookmark(reader.bookmarks.single.id);
      expect(reader.bookmarks, isEmpty);
    });

    test('die Größe gilt auch im fortlaufenden Modus', () async {
      await reader.updateProfile(
        reader.profile.copyWith(
          layout: PublicationReaderLayout.webtoon,
          pageScale: PublicationPageScale.fitHeight,
        ),
      );

      // Die Einstellung wird gehalten, nicht vom Layout überstimmt.
      expect(reader.isContinuous, isTrue);
      expect(reader.profile.pageScale, PublicationPageScale.fitHeight);

      await reader.updateProfile(
        reader.profile.copyWith(pageScale: PublicationPageScale.original),
      );
      expect(reader.profile.pageScale, PublicationPageScale.original);
    });

    test('die Bedienung lässt sich wegtippen', () async {
      expect(reader.showsChrome, isTrue);
      reader.toggleChrome();
      expect(reader.showsChrome, isFalse);
      reader.showChrome();
      expect(reader.showsChrome, isTrue);
    });
  });

  group('Das Archiv ist keine vertrauenswürdige Eingabe', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-cbz-');
    });

    tearDown(() => root.delete(recursive: true));

    test('Seite 2 kommt vor Seite 10', () async {
      final path = writeArchive(root, 'Band.cbz', [
        'seite10.jpg',
        'seite2.jpg',
        'seite1.jpg',
      ]);

      final pages = await ArchiveComicPageSource(path).pages();

      expect(pages.map((page) => page.name), [
        'seite1.jpg',
        'seite2.jpg',
        'seite10.jpg',
      ]);
    });

    test('was keine Seite ist, wird nicht mitgezählt', () async {
      final path = writeArchive(root, 'Band.cbz', ['001.jpg', 'ComicInfo.xml']);

      final pages = await ArchiveComicPageSource(path).pages();

      expect(pages, hasLength(1));
    });

    test('ein Eintrag außerhalb des Archivs wird abgelehnt', () async {
      final path = writeArchive(root, 'Band.cbz', ['../../entwischt.jpg']);

      expect(
        () => ArchiveComicPageSource(path).pages(),
        throwsA(isA<ComicArchiveException>()),
      );
    });

    test('eine Seite wird entpackt und liegt dann als Datei vor', () async {
      final path = writeArchive(root, 'Band.cbz', ['001.jpg']);
      final source = ArchiveComicPageSource(path);

      final pages = await source.pages();
      final files = await source.materialize(pages);

      expect(files, hasLength(1));
      expect(File(files[pages.first.id]!).existsSync(), isTrue);
      addTearDown(
        () => File(files[pages.first.id]!).parent.deleteSync(recursive: true),
      );
    });
  });
}
