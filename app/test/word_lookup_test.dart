import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/metadata/word_lookup.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Looking a word up sends that word and nothing else, and reads what
/// Wiktionary answers without trusting it to be tidy.
void main() {
  const germanExtract = '''
== Haus (Deutsch) ==
=== Substantiv, n ===
Worttrennung:
Haus, Plural: Häu·ser
Bedeutungen:
[1] Gebäude, das Menschen zum Wohnen dient
[2] Familie oder Herrscherhaus
Herkunft:
mittelhochdeutsch hūs
''';

  test('German meanings are read from the extract', () {
    final parsed = WordLookup.parseGermanExtract(germanExtract);
    expect(parsed.partOfSpeech, 'Substantiv');
    expect(parsed.meanings, [
      'Gebäude, das Menschen zum Wohnen dient',
      'Familie oder Herrscherhaus',
    ]);
  });

  test('English definitions lose their markup', () {
    final parsed = WordLookup.parseEnglishDefinitions({
      'en': [
        {
          'partOfSpeech': 'Noun',
          'definitions': [
            {
              'definition':
                  'A <a href="/wiki/building">building</a> &amp; home.',
            },
          ],
        },
      ],
    }, language: 'en');
    expect(parsed.partOfSpeech, 'Noun');
    expect(parsed.meanings, ['A building & home.']);
  });

  test('a selection that is no word is not looked up', () {
    expect(WordLookup.clean('  „Haus,“ '), 'Haus');
    expect(WordLookup.clean('...'), isNull);
    expect(WordLookup.clean('eins zwei drei vier fünf'), isNull);
  });

  test('only the word goes out, and a capitalised start is tried', () async {
    final asked = <Uri>[];
    final lookup = WordLookup(
      client: MockClient((request) async {
        asked.add(request.url);
        final title = request.url.queryParameters['titles'];
        if (title == 'Haus') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'query': {
                  'pages': {
                    '1': {'title': 'Haus', 'extract': germanExtract},
                  },
                },
              }),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'query': {
              'pages': {
                '-1': {'title': title, 'missing': ''},
              },
            },
          }),
          200,
        );
      }),
    );
    addTearDown(lookup.close);

    final result = await lookup.lookup('haus,', language: 'de');
    expect(result?.word, 'Haus');
    expect(result?.meanings, hasLength(2));
    expect(result?.source.host, 'de.wiktionary.org');
    for (final uri in asked) {
      expect(uri.scheme, 'https');
      expect(uri.queryParameters.keys, isNot(contains('book')));
    }
  });
}
