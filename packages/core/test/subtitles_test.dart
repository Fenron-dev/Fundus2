import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Subtitle files beside a video used to be ignored by the scanner, so a
/// film that came with its German subtitles played without them — locally,
/// streamed and offline alike.
void main() {
  ({
    String fileId,
    String filename,
    String relativePath,
    int sizeBytes,
    String contentRevision,
  })
  subtitle(String filename) => (
    fileId: filename,
    filename: filename,
    relativePath: filename,
    sizeBytes: 1,
    contentRevision: '',
  );

  group('matching', () {
    test('a film takes its subtitles and reads their names', () {
      final matched = matchSubtitles(
        [(fileId: 'film', filename: 'Nordwind (2019).mkv')],
        [
          subtitle('Nordwind (2019).de.srt'),
          subtitle('Nordwind (2019).en.forced.srt'),
          subtitle('Nordwind (2019).English.SDH.ass'),
          subtitle('English.srt'),
          subtitle('Nordwind (2019).nfo'),
        ],
      );
      final film = matched['film']!;
      expect(film.map((item) => item.filename), [
        'Nordwind (2019).de.srt',
        'English.srt',
        'Nordwind (2019).English.SDH.ass',
        'Nordwind (2019).en.forced.srt',
      ]);
      expect(film.first.language, 'de');
      expect(film.first.label, 'Deutsch (Datei)');
      final forced = film.last;
      expect(forced.language, 'en');
      expect(forced.forced, isTrue);
      expect(forced.label, 'Englisch · erzwungen (Datei)');
      expect(film[2].hearingImpaired, isTrue);
      // The only video in the folder owns a subtitle that names nothing.
      expect(film[1].language, 'en');
    });

    test('episodes keep their own subtitles, even 1 and 10', () {
      final matched = matchSubtitles(
        [
          (fileId: 'e1', filename: 'Folge 1.mkv'),
          (fileId: 'e10', filename: 'Folge 10.mkv'),
        ],
        [
          subtitle('Folge 1.de.srt'),
          subtitle('Folge 10.de.srt'),
          subtitle('Folge 10.srt'),
          subtitle('Bonus.de.srt'),
        ],
      );
      expect(matched['e1']!.map((item) => item.filename), ['Folge 1.de.srt']);
      expect(matched['e10']!.map((item) => item.filename), [
        'Folge 10.de.srt',
        'Folge 10.srt',
      ]);
      // A subtitle that names no episode is not guessed onto one.
      expect(
        matched.values.expand((list) => list).map((item) => item.filename),
        isNot(contains('Bonus.de.srt')),
      );
    });
  });

  group('library', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-subtitles-');
    });

    tearDown(() => root.delete(recursive: true));

    test(
      'subtitles beside a film reach its track, never its content',
      () async {
        final folder = Directory('${root.path}/Filme/Nordwind (2019)')
          ..createSync(recursive: true);
        File('${folder.path}/Nordwind (2019).mkv').writeAsBytesSync([1, 2, 3]);
        File(
          '${folder.path}/Nordwind (2019).de.srt',
        ).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nHallo\n');
        Directory('${folder.path}/Subs').createSync();
        File('${folder.path}/Subs/English.srt').writeAsStringSync('1\n');
        // Subtitles with nothing to accompany are no work of their own.
        final lonely = Directory('${root.path}/Filme/Nur Untertitel')
          ..createSync(recursive: true);
        File('${lonely.path}/Etwas.de.srt').writeAsStringSync('1\n');

        final library = await FundusLibrary.create(root);
        addTearDown(library.close);
        await library.index().drain<void>();

        final work = library.listWorks().single;
        expect(work.title, contains('Nordwind'));
        expect(library.contentFiles(work.id).map((file) => file.filename), [
          'Nordwind (2019).mkv',
        ]);
        final track = library.playbackTracks(work.id).single;
        expect(track.subtitles.map((item) => item.language), ['de', 'en']);
        for (final item in track.subtitles) {
          expect(item.isRemote, isFalse);
          expect(File(item.absolutePath).existsSync(), isTrue);
        }
        expect(
          library.workIdForSubtitle(track.subtitles.first.fileId),
          work.id,
        );
        expect(
          library.companionFiles(work.id).map((file) => file.filename),
          containsAll(['Nordwind (2019).de.srt', 'English.srt']),
        );
      },
    );

    test('a mirrored film carries its subtitles from the other side', () async {
      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      library.registerPeerSource(
        sourceId: 'peer-1',
        displayName: 'Desktop',
        libraryId: 'lib-1',
        baseUrl: 'https://127.0.0.1:1',
      );
      library.mirrorRemoteCatalogue(
        sourceId: 'peer-1',
        works: const [
          RemoteWorkRecord(
            id: 'w-film',
            kind: 'movie',
            title: 'Nordwind',
            files: [
              RemoteFileRecord(
                id: 'f-film',
                filename: 'Nordwind.mkv',
                position: 0,
                extension: '.mkv',
                subtitles: [
                  RemoteFileRecord(
                    id: 'f-sub-de',
                    filename: 'Nordwind.de.srt',
                    position: 0,
                    extension: '.srt',
                    contentRevision: 'rev-1',
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      final track = library.playbackTracks('w-film').single;
      final mirrored = track.subtitles.single;
      expect(mirrored.isRemote, isTrue);
      expect(mirrored.sourceId, 'peer-1');
      expect(mirrored.absolutePath, isEmpty);
      expect(mirrored.language, 'de');
      expect(mirrored.contentRevision, 'rev-1');
      // Not content: the film counts as one file.
      expect(library.contentFiles('w-film'), hasLength(1));
    });
  });
}
