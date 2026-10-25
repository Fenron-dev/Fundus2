import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/text_reader_controller.dart';
import 'package:fundus_core/fundus_core.dart';

/// A stand-in for an EPUB: the chapters are given, not parsed.
final class FakeTextSource implements TextSource {
  FakeTextSource(this.name, this.titles);

  @override
  final String name;
  final List<String> titles;

  @override
  Future<List<TextChapter>> chapters() async => [
    for (final title in titles)
      TextChapter(
        id: 'chapter-$title',
        title: title,
        document: ReflowDocument.parse(
          List.generate(
            8,
            (index) =>
                'Absatz $index von $title. '
                'Hier steht so viel Text, dass ein Anteil überhaupt '
                'etwas bedeutet.',
          ).join('\n\n'),
          format: ReflowSourceFormat.plainText,
        ),
      ),
  ];
}

/// Builds an EPUB good enough for the real adapter to open.
///
/// The shape follows the fixture in the core package: the parser wants an
/// EPUB 2 spine with an NCX table of contents, and a hand-rolled EPUB 3
/// without one is rejected as damaged.
String writeEpub(Directory directory, String name, List<String> chapters) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    );

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navigation = StringBuffer();
  for (var index = 0; index < chapters.length; index++) {
    manifest.writeln(
      '    <item id="chapter-$index" href="Text/chapter-$index.xhtml" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.writeln('    <itemref idref="chapter-$index"/>');
    navigation.writeln(
      '    <navPoint id="chapter-$index" playOrder="${index + 1}">'
      '<navLabel><text>${chapters[index]}</text></navLabel>'
      '<content src="Text/chapter-$index.xhtml"/></navPoint>',
    );
    archive.addFile(
      ArchiveFile.string(
        'OEBPS/Text/chapter-$index.xhtml',
        '<html><head><title>${chapters[index]}</title></head><body>'
            '<p>Der erste Absatz von ${chapters[index]}, lang genug, um einen '
            'Anteil sinnvoll zu machen.</p>'
            '<p>Ein zweiter Absatz, damit es etwas zu blättern gibt.</p>'
            '</body></html>',
      ),
    );
  }

  archive
    ..addFile(
      ArchiveFile.string(
        'OEBPS/content.opf',
        '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">urn:uuid:fundus-test</dc:identifier>
    <dc:title>Glasmeer</dc:title>
    <dc:language>de</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
$manifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
</package>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/toc.ncx',
        '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:fundus-test"/></head>
  <docTitle><text>Glasmeer</text></docTitle>
  <navMap>
$navigation  </navMap>
</ncx>''',
      ),
    );

  final path = '${directory.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

/// Answers only when told to, which is how „was zeigt er, während er lädt?"
/// becomes a question a test can ask.
final class SlowTextSource implements TextSource {
  SlowTextSource(this.name, this.titles);

  final _gate = Completer<void>();

  @override
  final String name;
  final List<String> titles;

  void answer() => _gate.complete();

  @override
  Future<List<TextChapter>> chapters() async {
    await _gate.future;
    return FakeTextSource(name, titles).chapters();
  }
}

void main() {
  group('Der Textleser rechnet im Kapitel, nicht in Seiten', () {
    late Directory root;
    late LibraryController library;
    late TextReaderController reader;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-text-');
      final work = Directory('${root.path}/Light Novels/Glasmeer')
        ..createSync(recursive: true);
      writeEpub(work, 'Band 01.epub', ['Erstes', 'Zweites']);
      // Was sonst noch im Ordner liegt und kein Text ist.
      File('${work.path}/cover.jpg').writeAsBytesSync(List.filled(64, 1));
      library = LibraryController();
      reader = TextReaderController(
        openSource: (path, name) =>
            FakeTextSource(name, const ['Kapitel eins', 'Kapitel zwei']),
      );
    });

    tearDown(() async {
      reader.dispose();
      await library.library?.flushSidecarWrites();
      library.dispose();
      await root.delete(recursive: true);
    });

    Future<void> openWork() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await reader.open(library.library!, library.works.first);
    }

    test('englische Werksprache erreicht die Vorleseauswahl', () async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      final original = library.works.first.summary;
      final updated = await library.library!.updateWorkMetadata(
        workId: original.id,
        title: original.title,
        authors: original.authors,
        language: 'en-US',
      );
      await reader.open(library.library!, WorkView.fromSummary(updated));
      final choice = reader.resolveSpeechLanguage(
        mediaTypeDefault: 'de',
        globalDefault: 'de',
      )!;
      expect(choice.language, SpeechLanguage.english);
      expect(choice.source, SpeechLanguageSource.workMetadata);
      expect(
        reader.resolveSpeechLanguage(workOverride: 'de')!.language,
        SpeechLanguage.german,
      );
    });

    test(
      'Novels verwenden Englisch als Standard vor der Gerätesprache',
      () async {
        await openWork();
        final base = library.works.first;
        final noLanguageMetadata = LibraryWorkSummary(
          id: base.id,
          kind: 'webnovel',
          title: base.title,
          author: base.summary.author,
          fileCount: base.summary.fileCount,
          addedAt: base.summary.addedAt,
        );
        await reader.open(
          library.library!,
          WorkView.fromSummary(noLanguageMetadata),
        );
        final choice = reader.resolveSpeechLanguage(globalDefault: 'de')!;
        expect(choice.language, SpeechLanguage.english);
        expect(choice.source, SpeechLanguageSource.mediaTypeDefault);
      },
    );

    test('an explicitly selected new volume starts at its beginning', () async {
      final folder = Directory('${root.path}/Light Novels/Glasmeer');
      writeEpub(folder, 'Band 02.epub', ['Neues']);
      await openWork();
      final work = library.works.first;
      final tracks = library.library!.playbackTracks(work.id);
      await reader.open(library.library!, work, startAt: tracks.last.fileId);
      expect(reader.failure, isNull);
      expect(reader.currentVolume?.fileId, tracks.last.fileId);
      expect(reader.chapterIndex, 0);
    });

    test(
      'an update opens its exact chapter without altering saved progress',
      () async {
        await openWork();
        final vault = library.library!;
        final work = library.works.first;
        final fileId = vault.playbackTracks(work.id).single.fileId;
        final before = vault.loadProgress(work.id)?.position.toJson();
        await reader.open(
          vault,
          work,
          startAt: fileId,
          chapterId: 'chapter-Kapitel zwei',
        );
        expect(reader.failure, isNull);
        expect(reader.chapterIndex, 1);
        expect(reader.currentChapter?.title, 'Kapitel zwei');
        expect(reader.paragraphIndex, 0);
        expect(reader.innerOffset, 0);
        expect(vault.loadProgress(work.id)?.position.toJson(), before);
      },
    );

    test(
      'a removed update chapter does not silently open chapter one',
      () async {
        await openWork();
        final vault = library.library!;
        final work = library.works.first;
        await reader.open(
          vault,
          work,
          startAt: vault.playbackTracks(work.id).single.fileId,
          chapterId: 'no-longer-present',
        );
        expect(reader.failure, contains('Kapitel ist nicht mehr verfügbar'));
        expect(reader.chapters, isEmpty);
      },
    );

    test('a removed update volume does not silently open volume one', () async {
      await openWork();
      await reader.open(
        library.library!,
        library.works.first,
        startAt: 'no-longer-present',
      );
      expect(reader.failure, contains('Band ist nicht mehr verfügbar'));
      expect(reader.chapters, isEmpty);
    });

    test(
      'das vorige Buch verschwindet, sobald ein neues geöffnet wird',
      () async {
        SlowTextSource? slow;
        final same = TextReaderController(
          openSource: (path, name) =>
              slow ?? FakeTextSource(name, const ['Kapitel eins']),
        );
        addTearDown(same.dispose);
        await library.open(root, createIfMissing: true);
        await library.scan();
        await same.open(library.library!, library.works.first);
        expect(same.chapters.single.title, 'Kapitel eins');

        // Derselbe Leser, das nächste Buch: der Moment dazwischen ist die Frage.
        slow = SlowTextSource('Band 02.epub', const ['Ganz anderes']);
        final opening = same.open(library.library!, library.works.first);
        await Future<void>.delayed(Duration.zero);

        expect(same.isBusy, isTrue);
        expect(
          same.chapters,
          isEmpty,
          reason:
              'das vorige Buch darf nicht stehen bleiben, '
              'während das nächste gelesen wird',
        );

        slow.answer();
        await opening;
        expect(same.chapters.single.title, 'Ganz anderes');
      },
    );

    test('eine Light Novel landet im Textleser', () async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      expect(TextReaderController.handles(library.works.first), isTrue);
    });

    test('das Cover ist kein Kapitel', () async {
      await openWork();

      expect(reader.failure, isNull);
      expect(reader.volumes, hasLength(1));
      expect(reader.volumes.single.title, endsWith('.epub'));
    });

    test('geöffnet wird beim ersten Kapitel, ganz vorn', () async {
      await openWork();

      expect(reader.chapters, hasLength(2));
      expect(reader.chapterIndex, 0);
      expect(reader.paragraphIndex, 0);
      expect(reader.positionLabel, contains('Kapitel eins'));
      expect(reader.positionLabel, contains('0 %'));
    });

    test('der Stand wird gemerkt und wieder aufgenommen', () async {
      await openWork();
      await reader.goToChapter(1);
      reader.reportPosition(4, .5);
      reader.saveProgress();

      final saved = library.library!.loadProgress(library.works.first.id);
      expect(saved, isNotNull);
      expect(saved!.position.kind, MediaPositionKind.epubCfi);
      expect(saved.position.chapterId, 'chapter-Kapitel zwei');
      // Das Etikett ist, was die Bibliothek in der Werkliste zeigt.
      expect(saved.position.label, 'Kapitel zwei');
      expect(saved.position.scrollOffset, closeTo(.5, .001));

      final again = TextReaderController(
        openSource: (path, name) =>
            FakeTextSource(name, const ['Kapitel eins', 'Kapitel zwei']),
      );
      addTearDown(again.dispose);
      await again.open(library.library!, library.works.first);

      expect(again.chapterIndex, 1);
      expect(again.paragraphIndex, 4);
    });

    test('der Anteil wächst mit dem Fortschritt im Kapitel', () async {
      await openWork();
      expect(reader.chapterFraction, closeTo(0, .01));

      reader.reportPosition(7, 1);
      expect(reader.chapterFraction, greaterThan(.8));
    });

    test(
      'nur abgespielte Vorleseabschnitte verschieben den Lesestand',
      () async {
        await openWork();
        final work = library.works.first;
        final plan = reader.speechPlan()!;
        final segment = plan.segments.first;
        expect(library.library!.loadProgress(work.id), isNull);

        // Synthese/Vorausladen allein dürfen den Stand nicht speichern.
        expect(reader.paragraphIndex, 0);
        expect(reader.innerOffset, 0);
        expect(library.library!.loadProgress(work.id), isNull);

        expect(reader.completeSpokenSegment(segment), isTrue);
        reader.checkpointSpeech();
        final saved = library.library!.loadProgress(work.id)!;
        expect(saved.position.kind, MediaPositionKind.epubCfi);
        expect(saved.position.chapterId, reader.currentChapter!.id);
        expect(saved.position.elementId, segment.endPosition.elementId);
        expect(saved.position.numericValue, segment.endPosition.numericValue);
        expect(saved.checkpoint, isTrue);

        final again = TextReaderController(
          openSource: (path, name) =>
              FakeTextSource(name, const ['Kapitel eins', 'Kapitel zwei']),
        );
        addTearDown(again.dispose);
        await again.open(library.library!, work);
        expect(again.paragraphIndex, reader.paragraphIndex);
        expect(again.innerOffset, closeTo(reader.innerOffset, .001));
        expect(
          again.speechPlan()!.segments.first.start,
          greaterThan(segment.end),
        );
      },
    );

    test(
      'veralteter Vorleseabschnitt überschreibt kein anderes Kapitel',
      () async {
        await openWork();
        final stale = reader.speechPlan()!.segments.first;
        await reader.goToChapter(1);
        final before = library.library!
            .loadProgress(library.works.first.id)!
            .position;
        expect(reader.completeSpokenSegment(stale), isFalse);
        reader.checkpointSpeech();
        final after = library.library!
            .loadProgress(library.works.first.id)!
            .position;
        expect(after.chapterId, before.chapterId);
        expect(after.numericValue, before.numericValue);
      },
    );

    test('das nächste Kapitel beginnt wieder ganz oben', () async {
      await openWork();
      reader.reportPosition(4, .75);

      await reader.nextChapter();

      expect(reader.chapterIndex, 1);
      expect(reader.paragraphIndex, 0);
      expect(reader.innerOffset, 0);
    });

    test('finishing a volume marks that file, not skipped volumes', () async {
      writeEpub(
        Directory('${root.path}/Light Novels/Glasmeer'),
        'Band 02.epub',
        ['Weiter'],
      );
      await openWork();
      await reader.goToChapter(1);
      await reader.nextChapter();
      expect(reader.volumeIndex, 1);
      expect(library.library!.finishedFiles(library.works.first.id), {
        reader.volumes.first.fileId,
      });
    });

    test('hinter dem letzten Kapitel ist Schluss, nicht Absturz', () async {
      await openWork();
      await reader.goToChapter(1);
      await reader.nextChapter();

      expect(reader.chapterIndex, 1);
      expect(reader.failure, isNull);
      final saved = library.library!.loadProgress(library.works.first.id);
      expect(saved?.finished, isTrue);
      reader.close();
      expect(
        library.library!.loadProgress(library.works.first.id)!.finished,
        isTrue,
      );
      expect(
        library.library!.loadProgress(library.works.first.id)!.checkpoint,
        isTrue,
      );
      await reader.open(library.library!, library.works.first);
      reader.close();
      expect(
        library.library!.loadProgress(library.works.first.id)!.finished,
        isTrue,
      );
    });

    test('die Schrifteinstellung wird gemerkt', () async {
      await openWork();
      await reader.updateProfile(
        reader.profile.copyWith(fontSize: 26, theme: ReflowTheme.sepia),
      );

      final again = TextReaderController(
        openSource: (path, name) => FakeTextSource(name, const ['Eins']),
      );
      addTearDown(again.dispose);
      await again.open(library.library!, library.works.first);

      expect(again.profile.fontSize, 26);
      expect(again.profile.theme, ReflowTheme.sepia);
    });

    test('eine Markierung hängt am Text, nicht am Layout', () async {
      await openWork();
      final text = reader.paragraphs[2].text;
      final start = text.indexOf('Anteil');

      await reader.addHighlight(
        paragraphIndex: 2,
        start: start,
        end: start + 'Anteil'.length,
      );

      expect(reader.highlights, hasLength(1));
      expect(reader.highlights.single.quote, 'Anteil');

      // Schriftgröße und Satzbreite ändern heißt: alles wird neu gesetzt.
      await reader.updateProfile(
        reader.profile.copyWith(fontSize: 34, contentWidth: 400),
      );

      final found = reader.highlightsInParagraph(2);
      expect(found, hasLength(1));
      expect(found.single.start, start);
      expect(found.single.end, start + 'Anteil'.length);
      // Und nicht in einem anderen Absatz.
      expect(reader.highlightsInParagraph(1), isEmpty);
    });

    test('eine Markierung übersteht das Schließen des Buchs', () async {
      await openWork();
      final text = reader.paragraphs[0].text;
      await reader.addHighlight(paragraphIndex: 0, start: 0, end: 6);
      expect(reader.highlights.single.quote, text.substring(0, 6));

      final again = TextReaderController(
        openSource: (path, name) =>
            FakeTextSource(name, const ['Kapitel eins', 'Kapitel zwei']),
      );
      addTearDown(again.dispose);
      await again.open(library.library!, library.works.first);

      expect(again.highlights, hasLength(1));
      expect(again.highlightsInParagraph(0), hasLength(1));

      await again.deleteHighlight(again.highlights.single.id);
      expect(again.highlights, isEmpty);
    });

    test(
      'eine Markierung in einem anderen Kapitel färbt hier nichts',
      () async {
        await openWork();
        await reader.addHighlight(paragraphIndex: 0, start: 0, end: 6);
        await reader.goToChapter(1);

        expect(reader.highlightsInParagraph(0), isEmpty);
      },
    );

    test('ein Lesezeichen überlebt eine andere Schriftgröße', () async {
      await openWork();
      reader.reportPosition(3, .5);
      await reader.addBookmark();
      await reader.updateProfile(reader.profile.copyWith(fontSize: 32));

      final again = TextReaderController(
        openSource: (path, name) =>
            FakeTextSource(name, const ['Kapitel eins', 'Kapitel zwei']),
      );
      addTearDown(again.dispose);
      await again.open(library.library!, library.works.first);
      await again.goToBookmark(again.bookmarks.single);

      // Der Anker ist der Absatz, nicht eine Pixelhöhe.
      expect(again.paragraphIndex, 3);
    });

    test('ein Lesezeichen führt zurück an seine Stelle', () async {
      await openWork();
      await reader.goToChapter(1);
      reader.reportPosition(5, .25);
      await reader.addBookmark(note: 'Die Wendung');
      await reader.goToChapter(0);

      expect(reader.bookmarks, hasLength(1));
      await reader.goToBookmark(reader.bookmarks.single);

      expect(reader.chapterIndex, 1);
      expect(reader.paragraphIndex, 5);
    });
  });

  group('Ein echtes EPUB wird gelesen', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-epub-');
    });

    tearDown(() => root.delete(recursive: true));

    test('Kapitel und Absätze kommen aus der Datei', () async {
      final path = writeEpub(root, 'Glasmeer.epub', [
        'Prolog',
        'Erstes Kapitel',
      ]);

      final chapters = await FileTextSource(path).chapters();

      expect(chapters, hasLength(2));
      expect(chapters.first.document.paragraphs, isNotEmpty);
      expect(
        chapters.first.document.paragraphs.map((p) => p.text).join(' '),
        contains('Prolog'),
      );
    });

    test('eine einfache Textdatei ist ein Kapitel', () async {
      final path = '${root.path}/notiz.txt';
      File(path).writeAsStringSync('Erster Absatz.\n\nZweiter Absatz.');

      final chapters = await FileTextSource(path).chapters();

      expect(chapters, hasLength(1));
      expect(chapters.single.document.paragraphs, hasLength(2));
    });

    test('eine kaputte Datei wirft, statt still zu bleiben', () async {
      final path = '${root.path}/kaputt.epub';
      File(path).writeAsBytesSync(List.filled(64, 9));

      expect(FileTextSource(path).chapters(), throwsA(isA<Object>()));
    });
  });
}
