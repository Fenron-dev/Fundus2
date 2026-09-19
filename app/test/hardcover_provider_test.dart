import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/metadata/metadata_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object value, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(value)),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _book(int id) => {'id': id, 'title': 'Buch $id'};

void main() {
  group('Hardcover', () {
    for (final token in ['token', ' Bearer token ', ' bearer   token ']) {
      test('normalizes copied authorization prefix: $token', () async {
        final client = MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer token');
          return _json({
            'data': {
              'search': {'ids': []},
            },
          });
        });
        expect(
          await HardcoverProvider(token: token, client: client).search('Book'),
          isEmpty,
        );
      });
    }

    test('rejects empty token before contacting the service', () async {
      final client = MockClient((_) async => throw StateError('network'));
      await expectLater(
        HardcoverProvider(token: ' ', client: client).search('Book'),
        throwsA(
          isA<MetadataProviderException>().having(
            (error) => error.message,
            'message',
            contains('Token fehlt'),
          ),
        ),
      );
    });

    test('does not turn a search service failure into no results', () async {
      final client = MockClient(
        (_) async => _json({
          'data': {
            'search': {'error': 'upstream unavailable', 'ids': []},
          },
        }),
      );
      await expectLater(
        HardcoverProvider(token: 'token', client: client).search('Book'),
        throwsA(
          isA<MetadataProviderException>().having(
            (error) => error.message,
            'message',
            contains('nicht verfügbar'),
          ),
        ),
      );
    });

    test('missing data is a response error, not no matches', () async {
      final client = MockClient((_) async => _json({'data': null}));
      await expectLater(
        HardcoverProvider(token: 'token', client: client).search('Book'),
        throwsA(isA<MetadataProviderException>()),
      );
    });

    test('401 explains how to renew the token without exposing it', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _json({'error': 'secret-should-not-be-shown'}, 401);
      });
      await expectLater(
        HardcoverProvider(
          token: 'secret-should-not-be-shown',
          client: client,
        ).search('Book'),
        throwsA(
          isA<MetadataProviderException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('hardcover.app/account/api'),
              isNot(contains('secret-should-not-be-shown')),
            ),
          ),
        ),
      );
      expect(calls, 1);
    });

    test('resolves Typesense hit ids and preserves relevance order', () async {
      var calls = 0;
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        if (calls++ == 0) {
          return _json({
            'data': {
              'search': {
                'ids': [],
                'results': jsonEncode({
                  'hits': [
                    {
                      'document': {
                        'id': '42',
                        'genres': ['Fantasy'],
                      },
                    },
                    {
                      'document': {'id': '17'},
                    },
                  ],
                }),
              },
            },
          });
        }
        expect(body['variables']['where'], {
          'id': {
            '_in': [42, 17],
          },
        });
        return _json({
          'data': {
            'books': [_book(17), _book(42)],
          },
        });
      });
      final result = await HardcoverProvider(
        token: 'token',
        client: client,
      ).search('Book');
      expect(result.map((book) => book.providerId), ['42', '17']);
      expect(result.first.genres, ['Fantasy']);
    });

    test(
      'imports writer roles, featured series and matching edition',
      () async {
        final client = MockClient((request) async {
          if (request.body.contains('query Search')) {
            return _json({
              'data': {
                'search': {
                  'ids': [42],
                },
              },
            });
          }
          return _json({
            'data': {
              'books': [
                {
                  ..._book(42),
                  'title': 'Über den Hügel',
                  'alternative_titles': ['Over the Hill', 'Über den Hügel'],
                  'release_date': '2020-01-01',
                  'contributions': [
                    {
                      'contribution': null,
                      'author': {'name': 'Writer'},
                    },
                    {
                      'contribution': 'Illustrator',
                      'author': {'name': 'Artist'},
                    },
                    {
                      'contribution': 'Translator',
                      'author': {'name': 'Translator'},
                    },
                  ],
                  'book_series': [
                    {
                      'featured': false,
                      'position': 99,
                      'series': {'name': 'Collected'},
                    },
                    {
                      'featured': true,
                      'position': '2.5',
                      'series': {'name': 'Hills'},
                    },
                  ],
                  'default_ebook_edition': {
                    'publisher': {'name': 'English Press'},
                    'language': {'code2': 'en'},
                  },
                  'default_physical_edition': {
                    'publisher': {'name': 'Deutscher Verlag'},
                    'language': {'code2': 'de'},
                  },
                  'cached_header_image': {
                    'url': 'https://images.example/banner.jpg',
                  },
                  'cached_image': {'url': 'https://images.example/cover.jpg'},
                },
              ],
            },
          });
        });
        final book = (await HardcoverProvider(
          token: 'token',
          client: client,
        ).search('Über den Hügel', language: 'de-DE')).single;
        expect(book.title, 'Über den Hügel');
        expect(book.authors, ['Writer']);
        expect(book.credits.map((person) => person.role), [
          'Author',
          'Illustrator',
          'Translator',
        ]);
        expect(book.series, 'Hills');
        expect(book.seriesSequence, 2.5);
        expect(book.alternateTitles, ['Over the Hill']);
        expect(book.releaseYear, 2020);
        expect(book.language, 'de');
        expect(book.publisher, 'Deutscher Verlag');
        expect(book.workKind, 'ebook');
        expect(book.posterUrl, 'https://images.example/cover.jpg');
        expect(book.backdropUrl, 'https://images.example/banner.jpg');
      },
    );

    for (final lookup in {
      'hardcover:42': {
        'id': {'_eq': 42},
      },
      'https://hardcover.app/books/the-way-of-kings': {
        'slug': {'_eq': 'the-way-of-kings'},
      },
    }.entries) {
      test('direct lookup avoids full-text search: ${lookup.key}', () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body) as Map;
          expect(body['query'], contains('query Books'));
          expect(body['variables']['where'], lookup.value);
          return _json({
            'data': {
              'books': [_book(42)],
            },
          });
        });
        expect(
          await HardcoverProvider(
            token: 'token',
            client: client,
          ).search(lookup.key),
          hasLength(1),
        );
        expect(calls, 1);
      });
    }

    test('transient service error is retried', () async {
      var calls = 0;
      final client = MockClient((_) async {
        if (calls++ == 0) return _json({'error': 'unavailable'}, 503);
        return _json({
          'data': {
            'search': {'ids': []},
          },
        });
      });
      expect(
        await HardcoverProvider(token: 'token', client: client).search('Book'),
        isEmpty,
      );
      expect(calls, 2);
    });
  });
}
