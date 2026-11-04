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

  // A word spelt the same in two languages: each has its own section.
  const twoLanguages = '''
== in (Deutsch) ==
=== Präposition ===
Bedeutungen:
[1] räumlich: innerhalb von etwas
Herkunft:
althochdeutsch in
== in (Englisch) ==
=== Präposition ===
Bedeutungen:
[1] in, innerhalb
[2] zeitlich: in, während
Herkunft:
altenglisch in
''';

  test('only the section of the book\'s language counts', () {
    final english = WordLookup.parseGermanExtract(
      twoLanguages,
      language: 'Englisch',
      strict: true,
    );
    expect(english.partOfSpeech, 'Präposition');
    expect(english.meanings, ['in, innerhalb', 'zeitlich: in, während']);
    final german = WordLookup.parseGermanExtract(
      twoLanguages,
      language: 'Deutsch',
    );
    expect(german.meanings, ['räumlich: innerhalb von etwas']);
  });

  test('a foreign word never borrows German meanings', () {
    // „Haus" has no English section; strictly, nothing is found.
    final strict = WordLookup.parseGermanExtract(
      germanExtract,
      language: 'Englisch',
      strict: true,
    );
    expect(strict.meanings, isEmpty);
    // Without any language heading a German page is still read whole.
    final bare = germanExtract.replaceFirst('== Haus (Deutsch) ==\n', '');
    final lenient = WordLookup.parseGermanExtract(bare, language: 'Deutsch');
    expect(lenient.meanings, hasLength(2));
    expect(
      WordLookup.parseGermanExtract(
        bare,
        language: 'Englisch',
        strict: true,
      ).meanings,
      isEmpty,
    );
  });

  test('an English book gets German meanings first', () async {
    const gift = '''
== gift (Englisch) ==
=== Substantiv ===
Bedeutungen:
[1] Geschenk, Gabe
[2] Begabung, Talent
Herkunft:
altnordisch gift
''';
    const poison = '''
== Gift (Deutsch) ==
=== Substantiv, n ===
Bedeutungen:
[1] Stoff, der Lebewesen schadet
''';
    final asked = <Uri>[];
    final lookup = WordLookup(
      client: MockClient((request) async {
        asked.add(request.url);
        final title = request.url.queryParameters['titles'];
        final extract = switch (title) {
          'gift' => gift,
          'Gift' => poison,
          _ => null,
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'query': {
                'pages': {
                  if (extract != null)
                    '1': {'title': title, 'extract': extract}
                  else
                    '-1': {'title': title, 'missing': ''},
                },
              },
            }),
          ),
          200,
        );
      }),
    );
    addTearDown(lookup.close);

    // At the start of a sentence: „Gift" is the German page, not the word.
    final result = await lookup.lookup('Gift,', language: 'en');
    expect(result?.word, 'gift');
    expect(result?.meanings, ['Geschenk, Gabe', 'Begabung, Talent']);
    expect(result?.source.host, 'de.wiktionary.org');
    expect(asked.map((uri) => uri.host), everyElement('de.wiktionary.org'));
  });

  test('what German Wiktionary does not know, English explains', () async {
    final asked = <Uri>[];
    final lookup = WordLookup(
      client: MockClient((request) async {
        asked.add(request.url);
        if (request.url.host == 'en.wiktionary.org') {
          return http.Response(
            jsonEncode({
              'en': [
                {
                  'partOfSpeech': 'Adjective',
                  'definitions': [
                    {'definition': 'Shining with reflected light.'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'query': {
              'pages': {
                '-1': {'title': 'lustrous', 'missing': ''},
              },
            },
          }),
          200,
        );
      }),
    );
    addTearDown(lookup.close);

    final result = await lookup.lookup('lustrous', language: 'eng');
    expect(result?.meanings, ['Shining with reflected light.']);
    expect(result?.source.host, 'en.wiktionary.org');
    expect(asked.first.host, 'de.wiktionary.org');
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
