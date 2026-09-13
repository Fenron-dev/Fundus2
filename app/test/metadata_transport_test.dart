import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/metadata/metadata_providers.dart';
import 'package:http/http.dart' as http;

/// Wie `FakeHttp`, aber die Kopfzeilen sind frei wählbar — der Fehler, um den
/// es hier geht, steckt genau darin.
final class RecordingHttp extends http.BaseClient {
  RecordingHttp(this.answer);

  final http.Response Function(http.BaseRequest request, int attempt) answer;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = answer(request, requests.length - 1);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      contentLength: response.bodyBytes.length,
    );
  }
}

http.Response _json(Object value, {Map<String, String>? headers}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      200,
      headers: headers ?? const {'content-type': 'application/json'},
    );

void main() {
  group('Antworten werden als UTF-8 gelesen', () {
    test('auch wenn der Dienst keinen Zeichensatz nennt', () async {
      // `package:http` faellt ohne `charset` auf latin1 zurueck. Jikan und
      // andere senden ein blankes `application/json`, und jeder japanische
      // Titel kam dadurch als Buchstabensalat an — noch bevor die Bewertung
      // ihn mit der Anfrage vergleichen konnte.
      final client = RecordingHttp(
        (request, attempt) => _json(
          {
            'data': [
              {
                'id': 'md-1',
                'attributes': {
                  'title': {'ja': 'ベルセルク', 'en': 'Berserk'},
                  'links': <String, String>{},
                  'contentRating': 'safe',
                },
              },
            ],
          },
          headers: const {'content-type': 'application/json'},
        ),
      );
      final found = await MangaDexProvider(client: client).search('Berserk');
      expect(found, hasLength(1));
      expect(found.single.alternateTitles, contains('ベルセルク'));
    });
  });

  group('MangaDex ist die Bruecke zu den Kennungen', () {
    test('liefert AniList- und MAL-Kennung aus dem links-Feld', () async {
      final client = RecordingHttp(
        (request, attempt) => _json({
          'data': [
            {
              'id': '0b1a-solo',
              'attributes': {
                'title': {'en': 'Solo Leveling'},
                'year': 2018,
                'originalLanguage': 'ko',
                'contentRating': 'safe',
                'links': {
                  'al': '179445',
                  'mal': '172429',
                  'raw': 'https://page.kakao.com/content/64612703',
                },
              },
            },
          ],
        }),
      );
      final found = await MangaDexProvider(
        client: client,
      ).search('Solo Leveling');
      expect(found, hasLength(1));
      expect(found.single.externalIds['anilist'], '179445');
      expect(found.single.externalIds['mal'], '172429');
      expect(found.single.externalIds['mangadex'], '0b1a-solo');
      expect(found.single.contentStyle, 'manhwa');
      expect(found.single.releaseYear, 2018);
    });

    test('ohne ausdrueckliche Freigabe wird nicht nach HHH gefragt', () async {
      final client = RecordingHttp((request, attempt) => _json({'data': []}));
      await MangaDexProvider(client: client).search('x');
      final ratings =
          client.requests.single.url.queryParametersAll['contentRating[]'];
      expect(ratings, isNot(contains('pornographic')));

      final adult = RecordingHttp((request, attempt) => _json({'data': []}));
      await MangaDexProvider(client: adult, includeAdult: true).search('x');
      expect(
        adult.requests.single.url.queryParametersAll['contentRating[]'],
        contains('pornographic'),
      );
    });
  });

  group('Die Suche fragt kuerzer nach, wenn nichts kommt', () {
    test(
      'ein verunreinigter Titel findet ueber die Leiter doch etwas',
      () async {
        // Gemessen: AniList liefert zu „Solo Leveling v01" null Treffer.
        // Geprueft wird ueber MangaDex, weil dessen Anfrage in der URL steht
        // und sich damit nachlesen laesst.
        final mangadex = RecordingHttp(
          (request, attempt) => _json({
            'data': [
              if (request.url.queryParameters['title'] == 'Solo Leveling')
                {
                  'id': 'md-solo',
                  'attributes': {
                    'title': {'en': 'Solo Leveling'},
                    'links': <String, String>{},
                    'contentRating': 'safe',
                  },
                },
            ],
          }),
        );
        final matches = await MetadataSearch([
          MangaDexProvider(client: mangadex),
        ]).search('Solo_Leveling_Vol_1');

        expect(matches, hasLength(1));
        expect(matches.single.candidate.title, 'Solo Leveling');
        expect(
          mangadex.requests.map(
            (request) => request.url.queryParameters['title'],
          ),
          contains('Solo Leveling'),
        );
      },
    );

    test(
      'eine genaue Anfrage wird nicht durch eine ungenauere ersetzt',
      () async {
        // „Blade Runner 2049" trifft sofort; die Leiter darf dann nicht
        // weiterlaufen und „Blade Runner" daruebersetzen.
        final client = RecordingHttp(
          (request, attempt) => _json({
            'data': [
              {
                'id': 'md-br',
                'attributes': {
                  'title': {'en': 'Blade Runner 2049'},
                  'links': <String, String>{},
                  'contentRating': 'safe',
                },
              },
            ],
          }),
        );
        final matches = await MetadataSearch([
          MangaDexProvider(client: client),
        ]).search('Blade Runner 2049');

        expect(matches.single.candidate.title, 'Blade Runner 2049');
        expect(client.requests, hasLength(1));
      },
    );
  });

  group('Wiederholt wird auch bei geworfenen Fehlern', () {
    test(
      'ein abgerissener Versuch wird nicht als Endergebnis genommen',
      () async {
        // Frueher pruefte die Schleife nur Statuscodes; ein geworfener Fehler
        // verliess sie beim ersten Versuch.
        var attempts = 0;
        final client = RecordingHttp((request, attempt) {
          attempts++;
          if (attempt == 0) throw http.ClientException('Verbindung weg');
          return _json({
            'data': [
              {
                'id': 'md-x',
                'attributes': {
                  'title': {'en': 'Nach dem zweiten Versuch'},
                  'links': <String, String>{},
                  'contentRating': 'safe',
                },
              },
            ],
          });
        });
        final found = await MangaDexProvider(client: client).search('x');
        expect(attempts, 2);
        expect(found.single.title, 'Nach dem zweiten Versuch');
      },
    );
  });
}
