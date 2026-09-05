import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/metadata/metadata_apply.dart';
import 'package:fundus/metadata/metadata_providers.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

/// Ein Dienst, der antwortet, was der Test ihm sagt — und mitschreibt, was
/// gefragt wurde.
final class FakeHttp extends http.BaseClient {
  FakeHttp(this.answer);

  final http.Response Function(http.BaseRequest request) answer;
  final List<Uri> asked = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    asked.add(request.url);
    final response = answer(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      contentLength: response.bodyBytes.length,
    );
  }
}

void main() {
  group('Was die Dienste sagen, wird zu einem Werk', () {
    test('AniList liefert Titel, Bild und die Leute dahinter', () async {
      final client = FakeHttp(
        (_) => http.Response(
          jsonEncode({
            'data': {
              'Page': {
                'media': [
                  {
                    'id': 30002,
                    'format': 'MANGA',
                    'isAdult': false,
                    'chapters': 364,
                    'startDate': {'year': 1989},
                    'title': {
                      'english': 'Berserk',
                      'romaji': 'Berserk',
                      'native': 'ベルセルク',
                    },
                    'description': 'Ein <i>langer</i>  Text.',
                    'coverImage': {'extraLarge': 'https://bild/gross.jpg'},
                    'genres': ['Action', 'Drama'],
                    'synonyms': ['Berserk: The Prototype'],
                    'staff': {
                      'edges': [
                        {
                          'role': 'Story & Art',
                          'node': {
                            'name': {'full': 'Kentarou Miura'},
                          },
                        },
                        {
                          'role': 'Assistant',
                          'node': {
                            'name': {'full': 'Nicht relevant'},
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      final results = await AniListProvider(
        type: 'MANGA',
        client: client,
      ).search('Berserk');

      final candidate = results.single;
      expect(candidate.title, 'Berserk');
      expect(candidate.workKind, 'manga');
      expect(candidate.authors, ['Kentarou Miura']);
      expect(candidate.releaseYear, 1989);
      expect(candidate.posterUrl, 'https://bild/gross.jpg');
      expect(candidate.description, 'Ein langer Text.');
      expect(candidate.alternateTitles, contains('ベルセルク'));
    });

    test(
      'Open Library braucht keinen Schlüssel und liefert ein Cover',
      () async {
        final client = FakeHttp(
          (_) => http.Response(
            jsonEncode({
              'docs': [
                {
                  'key': '/works/OL123W',
                  'title': 'Die Verwandlung',
                  'author_name': ['Franz Kafka'],
                  'first_publish_year': 1915,
                  'cover_i': 8231856,
                  'subject': ['Fiction'],
                  'publisher': ['Kurt Wolff'],
                  'language': ['ger'],
                },
              ],
            }),
            200,
          ),
        );

        final results = await OpenLibraryProvider(
          client: client,
        ).search('Kafka');

        final candidate = results.single;
        expect(candidate.providerId, 'OL123W');
        expect(candidate.authors, ['Franz Kafka']);
        expect(
          candidate.posterUrl,
          'https://covers.openlibrary.org/b/id/8231856-L.jpg',
        );
        expect(client.asked.single.queryParameters['q'], 'Kafka');
      },
    );

    test('TMDB ohne Schlüssel fragt gar nicht erst', () async {
      final client = FakeHttp((_) => http.Response('{}', 200));

      await expectLater(
        TmdbProvider(apiKey: '', client: client).search('Dune'),
        throwsA(isA<MetadataProviderException>()),
      );
      expect(client.asked, isEmpty, reason: 'kein Schlüssel, keine Anfrage');
    });

    test('ein Dienst, der ausfällt, verdeckt den anderen nicht', () async {
      final broken = FakeHttp((_) => http.Response('kaputt', 500));
      final working = FakeHttp(
        (_) => http.Response(
          jsonEncode({
            'docs': [
              {
                'key': '/works/OL9W',
                'title': 'Dune',
                'author_name': ['Frank Herbert'],
              },
            ],
          }),
          200,
        ),
      );

      final matches = await MetadataSearch([
        AniListProvider(client: broken),
        OpenLibraryProvider(client: working),
      ]).search('Dune');

      expect(matches.single.candidate.title, 'Dune');
    });

    test('das Jahr trennt die Neuverfilmung vom Original', () {
      final matches = rankMetadataCandidates('Dune', const [
        MetadataCandidate(
          provider: 'tmdb',
          providerId: '1',
          title: 'Dune',
          releaseYear: 1984,
        ),
        MetadataCandidate(
          provider: 'tmdb',
          providerId: '2',
          title: 'Dune',
          releaseYear: 2021,
        ),
      ], year: 2021);

      expect(matches.first.candidate.providerId, '2');
      expect(matches.first.reasons, contains('Gleiches Jahr'));
    });
  });

  group('Übernommen wird, ohne zu überschreiben, was von Hand kam', () {
    late Directory root;
    late FundusLibrary library;
    late WorkView work;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-meta-');
      final folder = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      await File('${folder.path}/001.cbz').writeAsBytes(List.filled(64, 1));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      work = WorkView.fromSummary(library.listWorks().single);
    });

    tearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });

    test('Titel, Jahr und Bild landen am Werk', () async {
      final client = FakeHttp(
        (_) => http.Response.bytes(List.filled(32, 7), 200),
      );

      final result = await applyMetadata(
        library: library,
        work: work,
        client: client,
        candidate: const MetadataCandidate(
          provider: 'anilist',
          providerId: '1',
          title: 'Berserk',
          authors: ['Kentarou Miura'],
          releaseYear: 1989,
          genres: ['Action'],
          posterUrl: 'https://bild/gross.jpg',
        ),
      );

      final updated = library.listWorks().single;
      expect(updated.title, 'Berserk');
      expect(updated.author, 'Kentarou Miura');
      expect(updated.publishedYear, 1989);
      expect(updated.genres, ['Action']);
      expect(result.coverFetched, isTrue);
      expect(updated.coverPath, isNotNull);
    });

    test(
      'ein von Hand gesetzter Titel überlebt den nächsten Abgleich',
      () async {
        await library.updateWorkMetadata(
          workId: work.id,
          title: 'So heißt es bei mir',
          authors: const ['Ich'],
        );

        await applyMetadata(
          library: library,
          work: WorkView.fromSummary(library.listWorks().single),
          fetchCover: false,
          candidate: const MetadataCandidate(
            provider: 'anilist',
            providerId: '1',
            title: 'Berserk',
            authors: ['Kentarou Miura'],
            releaseYear: 1989,
          ),
        );

        final updated = library.listWorks().single;
        expect(updated.title, 'So heißt es bei mir');
        expect(updated.author, 'Ich');
        // Was noch leer war, wird trotzdem gefüllt.
        expect(updated.publishedYear, 1989);
      },
    );

    test('ein Breitbild wird neben dem Titelbild abgelegt', () async {
      final client = FakeHttp(
        (_) => http.Response.bytes(List.filled(32, 9), 200),
      );

      final result = await applyMetadata(
        library: library,
        work: work,
        client: client,
        candidate: const MetadataCandidate(
          provider: 'tmdb',
          providerId: '7',
          title: 'Berserk',
          posterUrl: 'https://bild/hochkant.jpg',
          backdropUrl: 'https://bild/breit.jpg',
        ),
      );

      final updated = library.listWorks().single;
      expect(result.backdropFetched, isTrue);
      expect(updated.backdropPath, isNotNull);
      // Getrennt abgelegt: die Bühne braucht das breite, die Kachel das hohe.
      expect(updated.backdropPath, isNot(updated.coverPath));
      expect(File(updated.backdropPath!).existsSync(), isTrue);
    });

    test('ein Titelbild im Ordner wird nicht ersetzt', () async {
      final folder = Directory('${root.path}/Manga/Mit Bild')
        ..createSync(recursive: true);
      await File('${folder.path}/001.cbz').writeAsBytes(List.filled(64, 2));
      await File('${folder.path}/cover.jpg').writeAsBytes(List.filled(8, 3));
      await library.index().drain<void>();
      final withCover = WorkView.fromSummary(
        library.listWorks().firstWhere((entry) => entry.title == 'Mit Bild'),
      );
      final client = FakeHttp(
        (_) => http.Response.bytes(List.filled(32, 7), 200),
      );

      final result = await applyMetadata(
        library: library,
        work: withCover,
        client: client,
        candidate: const MetadataCandidate(
          provider: 'anilist',
          providerId: '2',
          title: 'Etwas anderes',
          posterUrl: 'https://bild/gross.jpg',
        ),
      );

      expect(result.coverFetched, isFalse);
      expect(client.asked, isEmpty);
    });
  });
}
