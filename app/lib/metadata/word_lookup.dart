import 'dart:convert';

import 'package:http/http.dart' as http;

import 'metadata_http_client.dart';

/// What a dictionary says about one word.
final class WordDefinition {
  const WordDefinition({
    required this.word,
    required this.meanings,
    required this.source,
    this.partOfSpeech,
  });

  final String word;
  final String? partOfSpeech;

  /// Short glosses, most common first.
  final List<String> meanings;

  /// The page the meanings come from, for the „open" link and attribution.
  final Uri source;
}

/// Looks up a word in Wiktionary.
///
/// Only ever asked on an explicit tap: the selected word is the one thing
/// that leaves the device, never the book, its title or the position. German
/// Wiktionary answers German texts in German; everything else is asked of
/// the English one, which describes words of most languages.
final class WordLookup {
  WordLookup({http.Client? client})
    : _client = client ?? createMetadataHttpClient();

  final http.Client _client;

  static const _timeout = Duration(seconds: 8);
  static const maximumMeanings = 6;

  /// [language] is the book's, as an ISO code or a name; null asks German
  /// first because the interface is German.
  Future<WordDefinition?> lookup(String word, {String? language}) async {
    final cleaned = clean(word);
    if (cleaned == null) return null;
    final german = language == null || _isGerman(language);
    for (final variant in _variants(cleaned)) {
      final found = german
          ? await _german(variant) ?? await _english(variant, 'de')
          : await _english(variant, _code(language));
      if (found != null) return found;
    }
    return null;
  }

  void close() => _client.close();

  /// The word as a dictionary would list it: no surrounding punctuation, at
  /// most a few words. Null for a selection that is no word.
  static String? clean(String selection) {
    final trimmed = selection
        .trim()
        .replaceAll(
          RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty || trimmed.length > 60) return null;
    if (trimmed.split(' ').length > 4) return null;
    return trimmed;
  }

  /// A word at the start of a sentence is capitalised, a German noun always
  /// is: try it as written, then the other way round.
  static List<String> _variants(String word) {
    final lower = word.toLowerCase();
    final capital = lower.isEmpty
        ? lower
        : lower[0].toUpperCase() + lower.substring(1);
    return {word, lower, capital}.toList(growable: false);
  }

  Future<WordDefinition?> _german(String word) async {
    final uri = Uri.https('de.wiktionary.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'prop': 'extracts',
      'explaintext': '1',
      'redirects': '1',
      'titles': word,
    });
    final decoded = await _get(uri);
    if (decoded == null) return null;
    final pages = (decoded['query'] as Map?)?['pages'];
    if (pages is! Map) return null;
    for (final page in pages.values) {
      if (page is! Map || page.containsKey('missing')) continue;
      final extract = page['extract'];
      if (extract is! String) continue;
      final parsed = parseGermanExtract(extract);
      if (parsed.meanings.isEmpty) continue;
      final title = page['title'] is String ? page['title'] as String : word;
      return WordDefinition(
        word: title,
        partOfSpeech: parsed.partOfSpeech,
        meanings: parsed.meanings,
        source: Uri.https('de.wiktionary.org', '/wiki/$title'),
      );
    }
    return null;
  }

  Future<WordDefinition?> _english(String word, String language) async {
    final uri = Uri.https(
      'en.wiktionary.org',
      '/api/rest_v1/page/definition/${Uri.encodeComponent(word)}',
    );
    final decoded = await _get(uri);
    if (decoded == null) return null;
    final parsed = parseEnglishDefinitions(decoded, language: language);
    if (parsed.meanings.isEmpty) return null;
    return WordDefinition(
      word: word,
      partOfSpeech: parsed.partOfSpeech,
      meanings: parsed.meanings,
      source: Uri.https('en.wiktionary.org', '/wiki/$word'),
    );
  }

  Future<Map<String, Object?>?> _get(Uri uri) async {
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'accept': 'application/json',
              'user-agent': metadataUserAgent,
            },
          )
          .timeout(_timeout);
      if (response.statusCode != 200 || response.bodyBytes.length > 2000000) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on Object {
      // No answer is an answer here: the sheet says nothing was found.
      return null;
    }
  }

  /// Reads the „Bedeutungen" of a German Wiktionary page as plain text.
  static ({String? partOfSpeech, List<String> meanings}) parseGermanExtract(
    String extract,
  ) {
    final lines = extract.split('\n').map((line) => line.trim()).toList();
    String? partOfSpeech;
    final meanings = <String>[];
    var inMeanings = false;
    for (final line in lines) {
      final heading = RegExp(r'^=+\s*(.+?)\s*=+$').firstMatch(line);
      if (heading != null) {
        final title = heading.group(1)!;
        // „Substantiv, n" or „Verb" as the heading of the first entry.
        if (partOfSpeech == null &&
            RegExp(
              r'^(Substantiv|Verb|Adjektiv|Adverb|Pronomen|Präposition|'
              r'Konjunktion|Interjektion|Partikel|Numerale|Eigenname)',
            ).hasMatch(title)) {
          partOfSpeech = title.split(',').first.trim();
        }
        if (inMeanings) break;
        continue;
      }
      if (line == 'Bedeutungen:') {
        inMeanings = true;
        continue;
      }
      if (!inMeanings) continue;
      if (line.isEmpty) continue;
      // The next block — „Herkunft:", „Synonyme:" — ends the meanings.
      if (RegExp(r'^[A-ZÄÖÜ][\wäöüß ]+:$').hasMatch(line)) break;
      final meaning = line
          .replaceFirst(RegExp(r'^\[\d+[a-z]?\]\s*'), '')
          .trim();
      if (meaning.isNotEmpty) meanings.add(meaning);
      if (meanings.length >= maximumMeanings) break;
    }
    return (partOfSpeech: partOfSpeech, meanings: meanings);
  }

  /// Reads the REST definitions of English Wiktionary for one language.
  static ({String? partOfSpeech, List<String> meanings})
  parseEnglishDefinitions(
    Map<String, Object?> decoded, {
    required String language,
  }) {
    final entries = decoded[language];
    if (entries is! List) return (partOfSpeech: null, meanings: const []);
    String? partOfSpeech;
    final meanings = <String>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      partOfSpeech ??= entry['partOfSpeech'] is String
          ? entry['partOfSpeech'] as String
          : null;
      final definitions = entry['definitions'];
      if (definitions is! List) continue;
      for (final definition in definitions) {
        if (definition is! Map || definition['definition'] is! String) {
          continue;
        }
        final text = _plain(definition['definition'] as String);
        if (text.isNotEmpty) meanings.add(text);
        if (meanings.length >= maximumMeanings) {
          return (partOfSpeech: partOfSpeech, meanings: meanings);
        }
      }
    }
    return (partOfSpeech: partOfSpeech, meanings: meanings);
  }

  static String _plain(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _isGerman(String language) {
    final value = language.toLowerCase().trim();
    return value == 'de' ||
        value.startsWith('de-') ||
        value == 'deu' ||
        value == 'ger' ||
        value == 'deutsch' ||
        value == 'german';
  }

  static String _code(String language) {
    final value = language.toLowerCase().trim();
    final code = value.split(RegExp(r'[-_]')).first;
    return switch (code) {
      'eng' || 'english' || 'englisch' => 'en',
      'fra' || 'fre' || 'french' || 'französisch' => 'fr',
      'spa' || 'spanish' || 'spanisch' => 'es',
      'ita' || 'italian' || 'italienisch' => 'it',
      'jpn' || 'japanese' || 'japanisch' => 'ja',
      _ => code.length == 2 ? code : 'en',
    };
  }
}
