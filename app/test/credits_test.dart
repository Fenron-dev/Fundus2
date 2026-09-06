import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/metadata/metadata_providers.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'metadata_test.dart' show FakeHttp;

/// Gesichter kommen aus dem Abgleich.
///
/// AniList führt Bilder zu Stab und Sprechern, TMDB zu Darstellern und Crew.
/// Erfunden wird keines; wo keines da ist, bleibt das Feld leer und die
/// Oberfläche setzt einen Platzhalter.
void main() {
  test('AniList bringt Stab und Sprecher mit Bild', () async {
    final client = FakeHttp(
      (_) => http.Response(
        jsonEncode({
          'data': {
            'Page': {
              'media': [
                {
                  'id': 1,
                  'format': 'TV',
                  'isAdult': false,
                  'title': {
                    'english': 'Chainsaw Man',
                    'romaji': 'Chainsaw Man',
                  },
                  'staff': {
                    'edges': [
                      {
                        'role': 'Director',
                        'node': {
                          'name': {'full': 'Ryu Nakayama'},
                          'image': {'large': 'https://bild/regie.jpg'},
                        },
                      },
                    ],
                  },
                  'characters': {
                    'edges': [
                      {
                        'role': 'MAIN',
                        'node': {
                          'name': {'full': 'Denji'},
                        },
                        'voiceActors': [
                          {
                            'name': {'full': 'Kikunosuke Toya'},
                            'image': {'large': 'https://bild/sprecher.jpg'},
                            'languageV2': 'Japanese',
                          },
                        ],
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

    final candidate = (await AniListProvider(
      client: client,
    ).search('Chainsaw Man')).single;

    expect(candidate.credits, hasLength(2));
    final director = candidate.credits.first;
    expect(director.name, 'Ryu Nakayama');
    expect(director.role, 'Director');
    expect(director.imageUrl, 'https://bild/regie.jpg');
    // Ein Sprechername ohne seine Figur ist nur ein Name.
    expect(candidate.credits.last.role, 'Sprecher · Denji');
    expect(candidate.credits.last.imageUrl, 'https://bild/sprecher.jpg');
  });

  test('TMDB holt die Besetzung erst für den gewählten Treffer', () async {
    var searches = 0;
    var credits = 0;
    final client = FakeHttp((request) {
      if (request.url.path.endsWith('/credits')) {
        credits++;
        return http.Response(
          jsonEncode({
            'cast': [
              {
                'name': 'Domhnall Gleeson',
                'character': 'Tim',
                'profile_path': '/tim.jpg',
              },
              {'name': 'Ohne Bild', 'character': 'Mary'},
            ],
            'crew': [
              {
                'name': 'Richard Curtis',
                'job': 'Director',
                'profile_path': '/r.jpg',
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      searches++;
      return http.Response(
        jsonEncode({
          'results': [
            {
              'id': 122906,
              'media_type': 'movie',
              'title': 'About Time',
              'release_date': '2013-08-16',
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final provider = TmdbProvider(apiKey: 'geheim', client: client);
    final found = (await provider.search('About Time')).single;

    // Die Suche allein fragt nicht nach der Besetzung.
    expect(found.credits, isEmpty);
    expect(credits, 0);
    expect(searches, 1);

    final full = await provider.enrich(found);

    expect(credits, 1);
    expect(full.credits.map((person) => person.name), [
      'Domhnall Gleeson',
      'Ohne Bild',
      'Richard Curtis',
    ]);
    expect(full.credits.first.role, 'Tim');
    expect(
      full.credits.first.imageUrl,
      'https://image.tmdb.org/t/p/w300/tim.jpg',
    );
    // Wo die Quelle kein Bild hat, wird keines erfunden.
    expect(full.credits[1].imageUrl, isNull);
    expect(full.credits.last.role, 'Director');
  });

  test('ohne Schlüssel bleibt der Treffer, wie er ist', () async {
    final candidate = const MetadataCandidate(
      provider: 'tmdb',
      providerId: '1',
      title: 'Irgendwas',
    );

    final same = await TmdbProvider(apiKey: '').enrich(candidate);

    expect(same.credits, isEmpty);
  });
}
