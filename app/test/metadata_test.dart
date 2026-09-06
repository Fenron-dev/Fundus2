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

    test('ein geholtes Bild darf ein besseres bekommen', () async {
      final client = FakeHttp(
        (_) => http.Response.bytes(List.filled(32, 7), 200),
      );
      const candidate = MetadataCandidate(
        provider: 'anilist',
        providerId: '1',
        title: 'Berserk',
        posterUrl: 'https://bild/gross.jpg',
      );

      await applyMetadata(
        library: library,
        work: work,
        client: client,
        candidate: candidate,
      );
      // Beim zweiten Abgleich lag schon ein Bild da — geholt, nicht im
      // Ordner. Wer erneut abgleicht, will das neuere Ergebnis.
      final again = await applyMetadata(
        library: library,
        work: WorkView.fromSummary(library.listWorks().single),
        client: client,
        candidate: candidate,
      );

      expect(again.coverFetched, isTrue);
    });
  });

  group('Podcasts kommen aus dem Apple-Verzeichnis', () {
    test('eine Antwort wird zu einem Vorschlag', () async {
      final client = FakeHttp(
        (request) => http.Response(
          jsonEncode({
            'resultCount': 1,
            'results': [
              {
                'collectionId': 1437,
                'collectionName': 'Lage der Nation',
                'artistName': 'Philip Banse & Ulf Buermeyer',
                'artworkUrl600': 'https://bild/podcast600.jpg',
                'genres': ['News', 'Podcasts', 'Politics'],
                'trackCount': 412,
                'releaseDate': '2026-08-30T04:00:00Z',
                'collectionExplicitness': 'cleaned',
                'feedUrl': 'https://lagedernation.org/feed/mp3/',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      final results = await ApplePodcastProvider(
        client: client,
      ).search('Lage der Nation');

      final candidate = results.single;
      expect(candidate.title, 'Lage der Nation');
      expect(candidate.authors, ['Philip Banse & Ulf Buermeyer']);
      expect(candidate.workKind, 'podcast');
      expect(candidate.episodeCount, 412);
      expect(candidate.releaseYear, 2026);
      expect(candidate.posterUrl, 'https://bild/podcast600.jpg');
      // Die Gattung ist kein Thema.
      expect(candidate.genres, ['News', 'Politics']);
      expect(candidate.externalIds['feed'], contains('lagedernation'));
    });

    test('eine Antwort ohne Kennung wird übergangen', () async {
      final client = FakeHttp(
        (request) => http.Response(
          jsonEncode({
            'results': [
              {'collectionName': 'Ohne Nummer'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      expect(
        await ApplePodcastProvider(client: client).search('irgendwas'),
        isEmpty,
      );
    });
  });

  group('Ein Podcast bringt die Texte seiner Folgen mit', () {
    late Directory root;
    late FundusLibrary library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-feed-');
      final show = Directory('${root.path}/Podcasts/Stay Forever')
        ..createSync(recursive: true);
      await File('${show.path}/sf100.mp3').writeAsBytes(List.filled(64, 1));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
    });

    tearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });

    test(
      'der Feed füllt die Folge, der Abgleich merkt sich die Adresse',
      () async {
        const feed = '''
<rss version="2.0"><channel>
  <item>
    <title>SF 100: Monkey Island</title>
    <description>Ein Spiel und ein Affe.</description>
    <pubDate>Tue, 02 Sep 2025 05:00:00 +0000</pubDate>
    <enclosure url="https://stayforever.de/media/sf100.mp3"/>
  </item>
</channel></rss>''';
        final client = FakeHttp(
          (request) => request.url.host == 'stayforever.de'
              ? http.Response(
                  feed,
                  200,
                  headers: {
                    'content-type': 'application/rss+xml; charset=utf-8',
                  },
                )
              : http.Response.bytes(List.filled(32, 7), 200),
        );

        final result = await applyMetadata(
          library: library,
          work: WorkView.fromSummary(library.listWorks().single),
          client: client,
          candidate: const MetadataCandidate(
            provider: 'apple_podcasts',
            providerId: '1',
            title: 'Stay Forever',
            externalIds: {
              'itunes': '1',
              'feed': 'https://stayforever.de/feed.xml',
            },
          ),
        );

        expect(result.episodesDescribed, 1);
        final fileId = library
            .playbackTracks(library.listWorks().single.id)
            .single
            .fileId;
        final detail = library.fileDetails(
          library.listWorks().single.id,
        )[fileId];
        expect(detail?.description, 'Ein Spiel und ein Affe.');
        expect(detail?.publishedAt, DateTime.utc(2025, 9, 2, 5));
        // Und die Adresse bleibt am Werk, für den nächsten Lauf.
        expect(
          library.listWorks().single.externalIds['feed'],
          'https://stayforever.de/feed.xml',
        );
      },
    );

    test('was der Feed nicht kennt, sagt die Datei selbst', () async {
      // Der Fall aus dem Ordner: mehrere Sendungen desselben Hauses liegen
      // beieinander, und ein Feed kennt immer nur seine eigene.
      final show = Directory('${root.path}/Podcasts/Stay Forever');
      await File('${show.path}/En Detail - Joel.mp3').writeAsBytes(
        _mp3WithComment(
          title: 'En Detail: Joel',
          comment: 'Ein Rabenvater.',
          date: '2026-04-30',
        ),
      );
      await library.index().drain<void>();
      const feed = '''
<rss version="2.0"><channel>
  <item>
    <title>SF 100: Monkey Island</title>
    <description>Ein Spiel und ein Affe.</description>
    <enclosure url="https://stayforever.de/media/sf100.mp3"/>
  </item>
</channel></rss>''';
      final client = FakeHttp(
        (request) => request.url.host == 'stayforever.de'
            ? http.Response(
                feed,
                200,
                headers: {'content-type': 'application/rss+xml; charset=utf-8'},
              )
            : http.Response.bytes(List.filled(32, 7), 200),
      );

      final workId = library.listWorks().single.id;
      final described = await describeEpisodes(
        library: library,
        workId: workId,
        feedUrl: 'https://stayforever.de/feed.xml',
        client: client,
      );

      expect(described, 2);
      final tracks = library.playbackTracks(workId);
      final details = library.fileDetails(workId);
      final fromFeed = tracks.firstWhere((t) => t.title.contains('sf100'));
      final fromTags = tracks.firstWhere((t) => t.title.contains('En Detail'));
      expect(details[fromFeed.fileId]?.description, 'Ein Spiel und ein Affe.');
      expect(details[fromTags.fileId]?.description, 'Ein Rabenvater.');
      expect(details[fromTags.fileId]?.publishedAt, DateTime.utc(2026, 4, 30));
    });

    test('ein Feed, der nicht antwortet, kostet nur die Texte', () async {
      final client = FakeHttp((_) => http.Response('kaputt', 500));

      final result = await applyMetadata(
        library: library,
        work: WorkView.fromSummary(library.listWorks().single),
        client: client,
        candidate: const MetadataCandidate(
          provider: 'apple_podcasts',
          providerId: '1',
          title: 'Stay Forever',
          externalIds: {'feed': 'https://stayforever.de/feed.xml'},
        ),
      );

      expect(result.episodesDescribed, 0);
      // Der Titel ist trotzdem übernommen.
      expect(library.listWorks().single.title, 'Stay Forever');
    });
  });

  group('Audible kennt die gesprochene Ausgabe', () {
    test('eine Antwort wird zu einem Vorschlag', () async {
      final client = FakeHttp(
        (_) => http.Response(
          jsonEncode({
            'products': [
              {
                'asin': 'B004V3W0KM',
                'title': 'Der Name des Windes',
                'subtitle': 'Die Königsmörder-Chronik 1',
                'authors': [
                  {'name': 'Patrick Rothfuss'},
                ],
                'narrators': [
                  {'name': 'Stefan Kaminski'},
                ],
                'publisher_name': 'Random House Audio',
                'release_date': '2008-10-20',
                'merchandising_summary': '<p>Kvothe erzählt sein Leben.</p>',
                'language': 'german',
                'product_images': {
                  '500': 'https://bild/500.jpg',
                  '1024': 'https://bild/1024.jpg',
                },
                'series': [
                  {'title': 'Die Königsmörder-Chronik', 'sequence': '1'},
                ],
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      final results = await AudibleProvider(
        client: client,
        host: 'api.audible.de',
      ).search('Der Name des Windes', language: 'de-DE');

      final candidate = results.single;
      expect(candidate.title, 'Der Name des Windes');
      // Wer schreibt steht vor wem liest — beide gehören zum Hörbuch.
      expect(candidate.authors, ['Patrick Rothfuss', 'Stefan Kaminski']);
      expect(candidate.series, 'Die Königsmörder-Chronik');
      expect(candidate.seriesSequence, 1);
      expect(candidate.releaseYear, 2008);
      expect(candidate.publisher, 'Random House Audio');
      expect(candidate.description, 'Kvothe erzählt sein Leben.');
      // Das größte Bild ist das, das eine Detailseite füllt.
      expect(candidate.posterUrl, 'https://bild/1024.jpg');
      expect(candidate.externalIds['asin'], 'B004V3W0KM');
      expect(candidate.workKind, 'audiobook');
      expect(client.asked.single.host, 'api.audible.de');
      expect(
        client.asked.single.queryParameters['title'],
        'Der Name des Windes',
      );
    });

    test('die Sprache entscheidet, welcher Shop antwortet', () {
      expect(AudibleProvider.hostFor('de-DE'), 'api.audible.de');
      expect(AudibleProvider.hostFor('en-US'), 'api.audible.com');
      expect(AudibleProvider.hostFor('en-GB'), 'api.audible.co.uk');
      expect(AudibleProvider.hostFor('ja-JP'), 'api.audible.co.jp');
      expect(AudibleProvider.hostFor('fr-FR'), 'api.audible.fr');
      // Ohne Angabe bleibt der größte Katalog übrig.
      expect(AudibleProvider.hostFor(null), 'api.audible.com');
    });

    test('ein Hörbuchregal bekommt Audible zuerst vorgeschlagen', () {
      expect(
        MetadataProviderKind.forMediaType('audiobook').first,
        MetadataProviderKind.audible,
      );
      // Ein Manga hat auf Audible nichts verloren.
      expect(
        MetadataProviderKind.forMediaType('manga'),
        isNot(contains(MetadataProviderKind.audible)),
      );
    });

    test('ein Eintrag ohne ASIN wird übergangen', () async {
      final client = FakeHttp(
        (_) => http.Response(
          jsonEncode({
            'products': [
              {'title': 'Ohne Kennung'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      expect(
        await AudibleProvider(
          client: client,
          host: 'api.audible.de',
        ).search('egal'),
        isEmpty,
      );
    });
  });

  group('Übernommen wird nur, was angehakt ist', () {
    late Directory root;
    late FundusLibrary library;
    late WorkView work;

    const candidate = MetadataCandidate(
      provider: 'audible',
      providerId: 'B1',
      title: 'Der Name des Windes',
      authors: ['Patrick Rothfuss'],
      publisher: 'Random House Audio',
      releaseYear: 2008,
      description: 'Kvothe erzählt sein Leben.',
      genres: ['Fantasy'],
      externalIds: {'asin': 'B1'},
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-fields-');
      final folder = Directory('${root.path}/Hörbücher/Wind')
        ..createSync(recursive: true);
      await File('${folder.path}/01.m4b').writeAsBytes(List.filled(64, 1));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      work = WorkView.fromSummary(library.listWorks().single);
    });

    tearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });

    test('ein abgewähltes Feld behält seinen Wert', () async {
      await library.updateWorkMetadata(
        workId: work.id,
        title: 'Wind',
        authors: ['Unbekannt'],
        description: 'Selbst geschrieben.',
      );
      work = WorkView.fromSummary(library.listWorks().single);

      await applyMetadata(
        library: library,
        work: work,
        candidate: candidate,
        fetchCover: false,
        fields: const {MetadataField.year, MetadataField.publisher},
      );

      final updated = library.listWorks().single;
      expect(updated.publishedYear, 2008);
      expect(updated.publisher, 'Random House Audio');
      // Titel und Beschreibung waren nicht angehakt — sie bleiben.
      expect(updated.title, 'Wind');
      expect(updated.description, 'Selbst geschrieben.');
      expect(updated.genres, isEmpty);
    });

    test('nur verknüpfen ändert kein sichtbares Feld', () async {
      await applyMetadata(
        library: library,
        work: work,
        candidate: candidate,
        fetchCover: false,
        fields: const {},
      );

      final updated = library.listWorks().single;
      expect(updated.title, work.summary.title);
      expect(updated.publishedYear, isNull);
      // Die Kennung ist trotzdem da — dafür macht man es.
      expect(updated.externalIds['asin'], 'B1');
    });

    test('ohne Auswahl bleibt es beim ganzen Treffer', () async {
      await applyMetadata(
        library: library,
        work: work,
        candidate: candidate,
        fetchCover: false,
      );

      final updated = library.listWorks().single;
      expect(updated.title, 'Der Name des Windes');
      expect(updated.genres, ['Fantasy']);
    });
  });
}

/// Eine MP3, die ihren eigenen Text mitbringt — so, wie ein Downloader sie
/// schreibt: Titel, Kommentar, Datum.
List<int> _mp3WithComment({
  required String title,
  required String comment,
  required String date,
}) {
  final frames = <int>[
    ..._id3Frame('TIT2', [0, ...latin1.encode(title)]),
    ..._id3Frame('COMM', [
      0,
      ...ascii.encode('deu'),
      0,
      ...latin1.encode(comment),
    ]),
    ..._id3Frame('TDRL', [0, ...latin1.encode(date)]),
  ];
  return [
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    (frames.length >> 21) & 0x7f,
    (frames.length >> 14) & 0x7f,
    (frames.length >> 7) & 0x7f,
    frames.length & 0x7f,
    ...frames,
  ];
}

List<int> _id3Frame(String id, List<int> payload) => [
  ...ascii.encode(id),
  (payload.length >> 24) & 0xff,
  (payload.length >> 16) & 0xff,
  (payload.length >> 8) & 0xff,
  payload.length & 0xff,
  0,
  0,
  ...payload,
];
