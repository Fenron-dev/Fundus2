import 'dart:async';
import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

/// A provider error carries no request URL and no credentials.
final class MetadataProviderException implements Exception {
  const MetadataProviderException(this.provider, this.message);

  final String provider;
  final String message;

  @override
  String toString() => '$provider: $message';
}

/// What a media area should be asked about, and where.
enum MetadataProviderKind {
  anilistAnime('AniList (Anime)'),
  anilistManga('AniList (Manga & Manhwa)'),
  tmdb('TMDB (Filme & Serien)'),
  openLibrary('Open Library (Bücher)'),
  audible('Audible (Hörbücher)'),
  applePodcasts('Apple Podcasts');

  const MetadataProviderKind(this.label);

  final String label;

  /// Whether this provider needs a key of the user's own.
  bool get needsKey => this == MetadataProviderKind.tmdb;

  /// The providers worth offering first for a media area.
  ///
  /// All of them stay reachable — a light novel has an AniList entry and an
  /// Open Library one, and which is the better answer depends on the book.
  static List<MetadataProviderKind> forMediaType(String? mediaTypeId) =>
      switch (mediaTypeId) {
        'anime' => const [
          MetadataProviderKind.anilistAnime,
          MetadataProviderKind.tmdb,
        ],
        'movie' || 'series' => const [
          MetadataProviderKind.tmdb,
          MetadataProviderKind.anilistAnime,
        ],
        'manga' => const [
          MetadataProviderKind.anilistManga,
          MetadataProviderKind.openLibrary,
        ],
        'novel' => const [
          MetadataProviderKind.anilistManga,
          MetadataProviderKind.openLibrary,
        ],
        'audiobook' => const [
          MetadataProviderKind.audible,
          MetadataProviderKind.openLibrary,
        ],
        'podcast' => const [
          MetadataProviderKind.applePodcasts,
          MetadataProviderKind.openLibrary,
        ],
        _ => const [
          MetadataProviderKind.openLibrary,
          MetadataProviderKind.anilistManga,
        ],
      };
}

abstract interface class MetadataProvider {
  String get provider;

  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  });
}

/// Builds the adapter for one choice.
///
/// Only TMDB takes a key, and it is passed in at the moment of the call — it
/// lives in the platform's secure storage and is never written into a vault.
MetadataProvider providerFor(
  MetadataProviderKind kind, {
  String apiKey = '',
  http.Client? client,
}) => switch (kind) {
  MetadataProviderKind.anilistAnime => AniListProvider(
    type: 'ANIME',
    client: client,
  ),
  MetadataProviderKind.anilistManga => AniListProvider(
    type: 'MANGA',
    client: client,
  ),
  MetadataProviderKind.tmdb => TmdbProvider(apiKey: apiKey, client: client),
  MetadataProviderKind.openLibrary => OpenLibraryProvider(client: client),
  MetadataProviderKind.audible => AudibleProvider(client: client),
  MetadataProviderKind.applePodcasts => ApplePodcastProvider(client: client),
};

/// Combines providers and applies the same local ranking to all of them.
///
/// One provider failing never hides another's results: a missing TMDB key is
/// not a reason to stop showing what AniList answered.
final class MetadataSearch {
  const MetadataSearch(this.providers);

  final List<MetadataProvider> providers;

  Future<List<MetadataMatch>> search(
    String query, {
    int limitPerProvider = 10,
    String? language,
    int? year,
  }) async {
    final responses = await Future.wait([
      for (final provider in providers)
        _safeSearch(provider, query, limitPerProvider, language),
    ]);
    return rankMetadataCandidates(
      query,
      responses.expand((candidates) => candidates),
      year: year,
    );
  }

  Future<List<MetadataCandidate>> _safeSearch(
    MetadataProvider provider,
    String query,
    int limit,
    String? language,
  ) async {
    try {
      return await provider.search(query, limit: limit, language: language);
    } on Object {
      return const [];
    }
  }
}

/// Public AniList GraphQL search. No account and no key.
final class AniListProvider implements MetadataProvider {
  AniListProvider({
    this.type = 'ANIME',
    http.Client? client,
    this.endpoint = _defaultEndpoint,
  }) : _client = client ?? http.Client();

  static const _defaultEndpoint = 'https://graphql.anilist.co';
  static const _query = r'''
query ($search: String!, $perPage: Int!, $type: MediaType!) {
  Page(perPage: $perPage) {
    media(search: $search, type: $type, sort: SEARCH_MATCH) {
      id
      type
      format
      isAdult
      episodes
      chapters
      volumes
      seasonYear
      startDate { year }
      title { romaji english native }
      description(asHtml: false)
      coverImage { extraLarge large medium }
      bannerImage
      genres
      synonyms
      staff(perPage: 4) {
        edges { role node { name { full } } }
      }
    }
  }
}
''';

  /// `ANIME` or `MANGA`. AniList's manga side carries manhwa and light
  /// novels too, which is where most of a Fundus manga shelf lives.
  final String type;
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'anilist';

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final response = await _request(
      _client.post(
        Uri.parse(endpoint),
        headers: const {
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'query': _query,
          'variables': {
            'search': normalizedQuery,
            'perPage': limit.clamp(1, 50),
            'type': type,
          },
        }),
      ),
    );
    final data = _decodeObject(response, provider);
    final dataValue = data['data'];
    final page = dataValue is Map ? dataValue['Page'] : null;
    final media = page is Map ? page['media'] : null;
    if (media is! List) return const [];
    return [
      for (final value in media)
        if (value is Map) ?_candidate(value, language: language),
    ];
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, 'Netzwerk: $error');
    }
  }

  MetadataCandidate? _candidate(Map value, {String? language}) {
    final id = value['id'];
    final titles = value['title'];
    if (id is! num || titles is! Map) return null;
    final title = _firstString(
      language?.toLowerCase().startsWith('ja') == true
          ? [titles['native'], titles['romaji'], titles['english']]
          : [titles['english'], titles['romaji'], titles['native']],
    );
    if (title == null) return null;
    final alternateTitles = <String>{
      for (final candidate in [
        titles['english'],
        titles['romaji'],
        titles['native'],
        ...(value['synonyms'] is List ? value['synonyms'] as List : const []),
      ])
        if (candidate is String && candidate.trim().isNotEmpty)
          candidate.trim(),
    }..remove(title);
    final format = value['format'];
    final isAdult = value['isAdult'] == true;
    final startYear = value['startDate'];
    return MetadataCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      alternateTitles: alternateTitles.toList(growable: false),
      authors: _staff(value['staff']),
      workKind: type == 'MANGA'
          ? 'manga'
          : format == 'MOVIE'
          ? 'movie'
          : 'tv',
      contentStyle: 'anime',
      contentSensitivity: isAdult ? 'adult_explicit' : null,
      releaseYear:
          (value['seasonYear'] as num?)?.round() ??
          (startYear is Map ? (startYear['year'] as num?)?.round() : null),
      episodeCount:
          (value['episodes'] as num?)?.round() ??
          (value['chapters'] as num?)?.round(),
      isAdult: isAdult,
      description: _cleanDescription(value['description']),
      genres: value['genres'] is List
          ? (value['genres'] as List).whereType<String>().toList(
              growable: false,
            )
          : const [],
      posterUrl:
          _stringFromMap(value['coverImage'], 'extraLarge') ??
          _stringFromMap(value['coverImage'], 'large') ??
          _stringFromMap(value['coverImage'], 'medium'),
      backdropUrl: value['bannerImage'] as String?,
      externalIds: {'anilist': '${id.round()}'},
    );
  }

  /// The people AniList lists as story or art, which is what „Urheber" means
  /// for a manga.
  static List<String> _staff(Object? value) {
    if (value is! Map) return const [];
    final edges = value['edges'];
    if (edges is! List) return const [];
    final names = <String>{};
    for (final edge in edges) {
      if (edge is! Map) continue;
      final role = '${edge['role'] ?? ''}'.toLowerCase();
      if (!role.contains('story') && !role.contains('art')) continue;
      final node = edge['node'];
      final name = node is Map ? node['name'] : null;
      final full = name is Map ? name['full'] : null;
      if (full is String && full.trim().isNotEmpty) names.add(full.trim());
    }
    return names.toList(growable: false);
  }
}

/// TMDB for films and series. The key is supplied at call time and never
/// serialized, logged or included in an error message.
final class TmdbProvider implements MetadataProvider {
  TmdbProvider({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  static const _endpoint = 'https://api.themoviedb.org/3/search/multi';
  final String apiKey;
  final http.Client _client;

  @override
  String get provider => 'tmdb';

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    if (apiKey.trim().isEmpty) {
      throw const MetadataProviderException(
        'tmdb',
        'Für TMDB wird ein eigener API-Schlüssel benötigt.',
      );
    }
    final response = await _request(
      _client.get(
        Uri.parse(_endpoint).replace(
          queryParameters: {
            'api_key': apiKey,
            'query': normalizedQuery,
            'include_adult': 'false',
            'language': language?.trim().isNotEmpty ?? false
                ? language!.trim()
                : 'de-DE',
          },
        ),
        headers: const {'accept': 'application/json'},
      ),
    );
    final data = _decodeObject(response, provider);
    final results = data['results'];
    if (results is! List) return const [];
    return [
      for (final value in results.take(limit.clamp(1, 50)))
        if (value is Map) ?_candidate(value),
    ];
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, 'Netzwerk: $error');
    }
  }

  MetadataCandidate? _candidate(Map value) {
    final id = value['id'];
    final mediaType = value['media_type'];
    if (id is! num || (mediaType != 'movie' && mediaType != 'tv')) return null;
    final title = _firstString([
      mediaType == 'movie' ? value['title'] : value['name'],
      mediaType == 'movie' ? value['original_title'] : value['original_name'],
    ]);
    if (title == null) return null;
    final alternate = _firstString([
      mediaType == 'movie' ? value['original_title'] : value['original_name'],
    ]);
    final date = _firstString([
      mediaType == 'movie' ? value['release_date'] : value['first_air_date'],
    ]);
    final isAdult = value['adult'] == true;
    return MetadataCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      alternateTitles: alternate == null || alternate == title
          ? const []
          : [alternate],
      workKind: mediaType == 'movie' ? 'movie' : 'tv',
      contentSensitivity: isAdult ? 'adult_explicit' : null,
      releaseYear: int.tryParse(date?.split('-').first ?? ''),
      isAdult: isAdult,
      description: _cleanDescription(value['overview']),
      language: value['original_language'] as String?,
      posterUrl: _tmdbImage(value['poster_path'], 'w500'),
      backdropUrl: _tmdbImage(value['backdrop_path'], 'w1280'),
      externalIds: {'tmdb': '${id.round()}'},
    );
  }
}

/// Open Library for books and e-books. No account and no key.
///
/// This is where Goodreads would have gone; its interface was withdrawn in
/// 2020 and a button that fails every time is worse than no button. Open
/// Library covers print and e-books, and for spoken editions Audible sits
/// beside it below.
final class OpenLibraryProvider implements MetadataProvider {
  OpenLibraryProvider({http.Client? client, this.endpoint = _defaultEndpoint})
    : _client = client ?? http.Client();

  static const _defaultEndpoint = 'https://openlibrary.org/search.json';
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'openlibrary';

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final response = await _request(
      _client.get(
        Uri.parse(endpoint).replace(
          queryParameters: {
            'q': normalizedQuery,
            'limit': '${limit.clamp(1, 50)}',
            'fields':
                'key,title,alternative_title,author_name,first_publish_year,'
                'cover_i,subject,publisher,language,number_of_pages_median',
          },
        ),
        headers: const {'accept': 'application/json'},
      ),
    );
    final data = _decodeObject(response, provider);
    final docs = data['docs'];
    if (docs is! List) return const [];
    return [
      for (final value in docs)
        if (value is Map) ?_candidate(value),
    ];
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, 'Netzwerk: $error');
    }
  }

  MetadataCandidate? _candidate(Map value) {
    final key = value['key'];
    final title = _firstString([value['title']]);
    if (key is! String || title == null) return null;
    final cover = value['cover_i'];
    List<String> strings(Object? raw, {int take = 8}) => raw is List
        ? raw.whereType<String>().take(take).toList(growable: false)
        : const [];
    return MetadataCandidate(
      provider: provider,
      providerId: key.replaceFirst('/works/', ''),
      title: title,
      alternateTitles: strings(value['alternative_title'], take: 4),
      authors: strings(value['author_name'], take: 4),
      workKind: 'ebook',
      releaseYear: (value['first_publish_year'] as num?)?.round(),
      publisher: strings(value['publisher'], take: 1).firstOrNull,
      language: strings(value['language'], take: 1).firstOrNull,
      genres: strings(value['subject']),
      posterUrl: cover is num
          ? 'https://covers.openlibrary.org/b/id/${cover.round()}-L.jpg'
          : null,
      externalIds: {'openlibrary': key.replaceFirst('/works/', '')},
    );
  }
}

/// Audible's own catalogue, through the interface its apps use.
///
/// Audiobookshelf asks the same address, and for the same reason: it is the
/// only place that knows a spoken edition as such — who read it, how long it
/// runs, which part of the series it is — where a print catalogue only knows
/// the book. There is no account and no key; the shop is asked in the
/// language the dialog is set to, because the German edition of a book has a
/// German title, a German blurb and a different reader than the English one.
final class AudibleProvider implements MetadataProvider {
  AudibleProvider({http.Client? client, this.host})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Overrides the shop derived from the language. Tests set it; nothing else
  /// needs to.
  final String? host;

  @override
  String get provider => 'audible';

  /// Which Audible shop answers for a language.
  ///
  /// Every shop carries its own catalogue, so a German search that went to
  /// the American shop would find the English edition and call it a match.
  static String hostFor(String? language) {
    final code = (language ?? '').toLowerCase().replaceAll('_', '-');
    final base = code.split('-').first;
    final region = code.contains('-') ? code.split('-').last : '';
    return switch ((base, region)) {
      ('de', _) => 'api.audible.de',
      ('ja', _) => 'api.audible.co.jp',
      ('fr', _) => 'api.audible.fr',
      ('es', _) => 'api.audible.es',
      ('it', _) => 'api.audible.it',
      ('en', 'gb' || 'uk') => 'api.audible.co.uk',
      ('en', 'au') => 'api.audible.com.au',
      ('en', 'in') => 'api.audible.in',
      ('en', 'ca') => 'api.audible.ca',
      _ => 'api.audible.com',
    };
  }

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final response = await _request(
      _client.get(
        Uri.https(host ?? hostFor(language), '/1.0/catalog/products', {
          'title': normalizedQuery,
          'num_results': '${limit.clamp(1, 50)}',
          'products_sort_by': 'Relevance',
          'response_groups':
              'contributors,product_desc,product_attrs,media,series',
        }),
        headers: const {'accept': 'application/json'},
      ),
    );
    final data = _decodeObject(response, provider);
    final products = data['products'];
    if (products is! List) return const [];
    return [
      for (final value in products)
        if (value is Map) ?_candidate(value, language: language),
    ];
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, 'Netzwerk: $error');
    }
  }

  MetadataCandidate? _candidate(Map value, {String? language}) {
    final asin = value['asin'];
    final title = _firstString([value['title']]);
    if (asin is! String || asin.trim().isEmpty || title == null) return null;
    final subtitle = _firstString([value['subtitle']]);
    final series = _firstSeries(value['series']);
    return MetadataCandidate(
      provider: provider,
      providerId: asin.trim(),
      title: title,
      alternateTitles: subtitle == null ? const [] : ['$title: $subtitle'],
      // Wer es geschrieben hat steht vorn, wer es gelesen hat dahinter — beide
      // gehören zum Werk, aber die Reihenfolge ist die eines Hörbuchregals.
      authors: [..._people(value['authors']), ..._people(value['narrators'])],
      workKind: 'audiobook',
      series: series?.$1,
      seriesSequence: series?.$2,
      releaseYear: _year(value['release_date'] ?? value['issue_date']),
      description: _cleanDescription(
        value['merchandising_summary'] ?? value['publisher_summary'],
      ),
      publisher: _firstString([value['publisher_name']]),
      language: _firstString([value['language']]) ?? language,
      isAdult: value['is_adult_product'] == true,
      posterUrl: _largestImage(value['product_images']),
      externalIds: {'audible': asin.trim(), 'asin': asin.trim()},
    );
  }

  static List<String> _people(Object? value) {
    if (value is! List) return const [];
    final names = <String>[];
    for (final entry in value.take(4)) {
      if (entry is! Map) continue;
      final name = _firstString([entry['name']]);
      if (name != null) names.add(name);
    }
    return names;
  }

  /// The first series Audible names, with the number inside it.
  ///
  /// „Band 3" darf auch „3.5" sein — Zwischenbände gibt es, und ein `int`
  /// würde sie auf den falschen Platz schieben.
  static (String, double?)? _firstSeries(Object? value) {
    if (value is! List) return null;
    for (final entry in value) {
      if (entry is! Map) continue;
      final title = _firstString([entry['title']]);
      if (title == null) continue;
      final sequence = entry['sequence'];
      return (
        title,
        sequence is num
            ? sequence.toDouble()
            : sequence is String
            ? double.tryParse(sequence.trim().replaceAll(',', '.'))
            : null,
      );
    }
    return null;
  }

  /// Audible keys its pictures by edge length. The largest is the one worth
  /// keeping — a cover that is shown full width on a desktop.
  static String? _largestImage(Object? value) {
    if (value is! Map) return null;
    var best = -1;
    String? url;
    for (final entry in value.entries) {
      final size = int.tryParse('${entry.key}') ?? 0;
      final candidate = _firstString([entry.value]);
      if (candidate != null && size > best) {
        best = size;
        url = candidate;
      }
    }
    return url;
  }

  static int? _year(Object? value) {
    if (value is! String || value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
  }
}

/// Apple's podcast directory, through the public search interface.
///
/// It is the one catalogue of podcasts that answers without an account, and
/// it knows what a shelf full of episode files does not: the show's own name,
/// who makes it, its subject tags and its artwork. There is no wide picture
/// here — a podcast has square artwork and nothing else — and no per-episode
/// detail; those live in the feed, which is a separate matter from matching
/// the show.
final class ApplePodcastProvider implements MetadataProvider {
  ApplePodcastProvider({http.Client? client, this.endpoint = _defaultEndpoint})
    : _client = client ?? http.Client();

  static const _defaultEndpoint = 'https://itunes.apple.com/search';
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'apple_podcasts';

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final response = await _request(
      _client.get(
        Uri.parse(endpoint).replace(
          queryParameters: {
            'term': normalizedQuery,
            'media': 'podcast',
            'entity': 'podcast',
            'limit': '${limit.clamp(1, 50)}',
            if (language != null && language.length == 2)
              'country': language.toUpperCase(),
          },
        ),
        headers: const {'accept': 'application/json'},
      ),
    );
    final data = _decodeObject(response, provider);
    final results = data['results'];
    if (results is! List) return const [];
    return [
      for (final value in results)
        if (value is Map) ?_candidate(value),
    ];
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, 'Netzwerk: $error');
    }
  }

  MetadataCandidate? _candidate(Map value) {
    final title = _firstString([value['collectionName'], value['trackName']]);
    final id = value['collectionId'];
    if (title == null || id is! num) return null;
    final genres = value['genres'] is List
        ? (value['genres'] as List)
              .whereType<String>()
              // „Podcasts" ist die Gattung, kein Thema.
              .where((genre) => genre.toLowerCase() != 'podcasts')
              .take(8)
              .toList(growable: false)
        : const <String>[];
    final host = _firstString([value['artistName']]);
    return MetadataCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      authors: [?host],
      workKind: 'podcast',
      releaseYear: _year(value['releaseDate']),
      episodeCount: (value['trackCount'] as num?)?.round(),
      genres: genres,
      isAdult: value['collectionExplicitness'] == 'explicit',
      posterUrl: _firstString([
        value['artworkUrl600'],
        value['artworkUrl100'],
        value['artworkUrl60'],
      ]),
      externalIds: {
        'itunes': '${id.round()}',
        'feed': ?_firstString([value['feedUrl']]),
      },
    );
  }

  static int? _year(Object? value) {
    if (value is! String || value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
  }
}

Map<String, Object?> _decodeObject(http.Response response, String provider) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw MetadataProviderException(
      provider,
      'Der Dienst hat mit einem Fehler geantwortet.',
    );
  }
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw const FormatException();
    if (decoded['errors'] is List && (decoded['errors'] as List).isNotEmpty) {
      throw MetadataProviderException(provider, 'Die Antwort ist ungültig.');
    }
    return Map<String, Object?>.from(decoded);
  } on MetadataProviderException {
    rethrow;
  } on Object {
    throw MetadataProviderException(provider, 'Die Antwort ist ungültig.');
  }
}

String? _firstString(Iterable<Object?> values) {
  for (final value in values) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _stringFromMap(Object? value, String key) =>
    value is Map && value[key] is String ? (value[key] as String).trim() : null;

String? _cleanDescription(Object? value) {
  if (value is! String) return null;
  final clean = value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.isEmpty ? null : clean;
}

String? _tmdbImage(Object? path, String size) =>
    path is String && path.isNotEmpty
    ? 'https://image.tmdb.org/t/p/$size$path'
    : null;
