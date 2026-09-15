import 'dart:async';
import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'metadata_http_client.dart';

/// A provider error carries no request URL and no credentials.
final class MetadataProviderException implements Exception {
  const MetadataProviderException(this.provider, this.message);

  final String provider;
  final String message;

  @override
  String toString() => '$provider: $message';
}

String _networkMessage(Object error) {
  final text = '$error';
  if (text.contains('Certificate_Verify_Failed') ||
      text.contains('HandshakeException')) {
    return 'TLS-Zertifikat konnte nicht geprüft werden. Fundus akzeptiert keine unsicheren Zertifikate.';
  }
  return 'Netzwerk: $error';
}

/// What a media area should be asked about, and where.
enum MetadataProviderKind {
  anilistAnime('AniList (Anime)'),
  anilistManga('AniList (Manga & Manhwa)'),
  anilistAdultAnime('AniList (Hentai Anime)'),
  anilistAdultManga('AniList (Hentai Manga & Novel)'),
  myAnimeList('MyAnimeList über Jikan (Ausweichweg)'),
  myAnimeListAdult('MyAnimeList über Jikan (Hentai)'),
  myAnimeListApi('MyAnimeList (Anime & Manga)'),
  myAnimeListApiAdult('MyAnimeList (Hentai)'),
  mangaDex('MangaDex (Manga, Manhwa & Manhua)'),
  mangaDexAdult('MangaDex (Hentai)'),
  tmdb('TMDB (Filme & Serien)'),
  openLibrary('Open Library (Bücher)'),
  hardcover('Hardcover.app (Bücher & Reihen)'),
  audible('Audible (Hörbücher)'),
  applePodcasts('Apple Podcasts');

  const MetadataProviderKind(this.label);

  final String label;

  /// Welches Zugangsdatum dieser Dienst braucht — oder `null`.
  ///
  /// Ein stabiler Schlüssel, keine Beschriftung: zwei Dienste können sich
  /// eines teilen (die beiden MyAnimeList-Einträge tun es), und der
  /// angezeigte Text darf sich ändern, ohne dass ein gespeichertes
  /// Zugangsdatum verlorengeht.
  String? get credentialKey => switch (this) {
    MetadataProviderKind.tmdb => 'tmdb',
    MetadataProviderKind.hardcover => 'hardcover',
    MetadataProviderKind.myAnimeListApi ||
    MetadataProviderKind.myAnimeListApiAdult => 'mal',
    _ => null,
  };

  /// Wie das Zugangsdatum heißt, das dieser Dienst braucht — oder `null`.
  ///
  /// Steht hier und nicht an drei Stellen in der Oberfläche: die Zuordnung von
  /// Dienst zu Zugangsdatum ist eine Eigenschaft des Dienstes, und als
  /// Fallunterscheidung im Dialog wäre sie beim nächsten Provider erneut zu
  /// pflegen — an jeder Stelle einzeln.
  String? get credentialLabel => switch (credentialKey) {
    'tmdb' => 'TMDB-Schlüssel',
    'hardcover' => 'Hardcover-API-Token',
    'mal' => 'MyAnimeList-Client-ID',
    _ => null,
  };

  /// Wo man sich dieses Zugangsdatum holt.
  String? get credentialSource => switch (credentialKey) {
    'tmdb' => 'themoviedb.org',
    'hardcover' => 'hardcover.app',
    'mal' => 'myanimelist.net/apiconfig',
    _ => null,
  };

  /// Whether this provider needs a key of the user's own.
  bool get needsKey => credentialLabel != null;

  /// The providers worth offering first for a media area.
  ///
  /// All of them stay reachable — a light novel has an AniList entry and an
  /// Open Library one, and which is the better answer depends on the book.
  static List<MetadataProviderKind> forMediaType(String? mediaTypeId) =>
      switch (mediaTypeId) {
        'anime' => const [
          MetadataProviderKind.anilistAnime,
          MetadataProviderKind.myAnimeListApi,
          MetadataProviderKind.tmdb,
          MetadataProviderKind.myAnimeList,
        ],
        'movie' || 'series' => const [
          MetadataProviderKind.tmdb,
          MetadataProviderKind.anilistAnime,
          MetadataProviderKind.myAnimeListApi,
        ],
        'manga' => const [
          MetadataProviderKind.mangaDex,
          MetadataProviderKind.anilistManga,
          MetadataProviderKind.myAnimeListApi,
          MetadataProviderKind.openLibrary,
          MetadataProviderKind.myAnimeList,
        ],
        'novel' => const [
          MetadataProviderKind.anilistManga,
          MetadataProviderKind.hardcover,
          MetadataProviderKind.mangaDex,
          MetadataProviderKind.myAnimeListApi,
          MetadataProviderKind.openLibrary,
        ],
        'book' => const [
          MetadataProviderKind.hardcover,
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
          MetadataProviderKind.mangaDex,
        ],
      };
}

abstract interface class MetadataProvider {
  String get provider;

  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  });

  /// Holt nach, was die Suche nicht mitliefert — heute die Besetzung.
  ///
  /// Getrennt von der Suche, weil es eine zweite Runde übers Netz ist: für
  /// zehn Treffer zehn Anfragen zu stellen, von denen neun weggeworfen
  /// werden, wäre die falsche Rechnung. Gefragt wird für den einen Treffer,
  /// den jemand übernimmt. Quellen, die schon alles gesagt haben, geben ihn
  /// unverändert zurück.
  Future<MetadataCandidate> enrich(MetadataCandidate candidate);
}

/// Builds the adapter for one choice.
///
/// Providers that need a credential receive it only at call time — it lives
/// in the platform's secure storage and is never written into a vault.
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
  MetadataProviderKind.anilistAdultAnime => AniListProvider(
    type: 'ANIME',
    includeAdult: true,
    client: client,
  ),
  MetadataProviderKind.anilistAdultManga => AniListProvider(
    type: 'MANGA',
    includeAdult: true,
    client: client,
  ),
  MetadataProviderKind.myAnimeList => MyAnimeListProvider(client: client),
  MetadataProviderKind.myAnimeListAdult => MyAnimeListProvider(
    includeAdult: true,
    client: client,
  ),
  MetadataProviderKind.myAnimeListApi => MyAnimeListApiProvider(
    clientId: apiKey,
    client: client,
  ),
  MetadataProviderKind.myAnimeListApiAdult => MyAnimeListApiProvider(
    clientId: apiKey,
    includeAdult: true,
    client: client,
  ),
  MetadataProviderKind.mangaDex => MangaDexProvider(client: client),
  MetadataProviderKind.mangaDexAdult => MangaDexProvider(
    includeAdult: true,
    client: client,
  ),
  MetadataProviderKind.tmdb => TmdbProvider(apiKey: apiKey, client: client),
  MetadataProviderKind.openLibrary => OpenLibraryProvider(client: client),
  MetadataProviderKind.hardcover => HardcoverProvider(
    token: apiKey,
    client: client,
  ),
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

  /// Sucht, und fragt bei null Treffern kürzer nach.
  ///
  /// Ein Werktitel kommt aus einem Dateinamen und trägt mit, was beim Ablegen
  /// praktisch war. Die Suchen der Dienste sind dagegen nahezu exakt: schon
  /// ein angehängtes Jahr genügt für null Treffer. Deshalb wird zuerst
  /// vollständig gefragt — eine genaue Anfrage soll nicht durch eine
  /// ungenauere ersetzt werden — und erst danach schrittweise kürzer.
  ///
  /// Bewertet wird am Ende gegen die Fassung, die etwas gefunden hat, nicht
  /// gegen den Rohtitel: sonst verlöre der Treffer ausgerechnet die Punkte für
  /// den Titel, wegen dessen Beiwerk er zuvor nicht gefunden wurde.
  Future<List<MetadataMatch>> search(
    String query, {
    int limitPerProvider = 25,
    String? language,
    int? year,
  }) async {
    MetadataProviderException? firstFailure;
    for (final step in searchQueryLadder(query)) {
      final responses = await Future.wait([
        for (final provider in providers)
          _safeSearch(provider, step, limitPerProvider, language),
      ]);
      final candidates = responses
          .expand((result) => result.candidates)
          .toList(growable: false);
      firstFailure ??= responses
          .map((result) => result.error)
          .whereType<MetadataProviderException>()
          .firstOrNull;
      if (candidates.isNotEmpty) {
        return rankMetadataCandidates(step, candidates, year: year);
      }
    }
    // Nichts gefunden. Lag ein Dienst quer, ist das die ehrlichere Auskunft
    // als „keine Treffer".
    if (firstFailure != null) throw firstFailure;
    return const [];
  }

  Future<
    ({List<MetadataCandidate> candidates, MetadataProviderException? error})
  >
  _safeSearch(
    MetadataProvider provider,
    String query,
    int limit,
    String? language,
  ) async {
    try {
      return (
        candidates: await provider.search(
          query,
          limit: limit,
          language: language,
        ),
        error: null,
      );
    } on MetadataProviderException catch (error) {
      return (candidates: const <MetadataCandidate>[], error: error);
    } on Object catch (error) {
      return (
        candidates: const <MetadataCandidate>[],
        error: MetadataProviderException(
          provider.provider,
          'Netzwerkfehler: $error',
        ),
      );
    }
  }
}

/// Public AniList GraphQL search. No account and no key.
final class AniListProvider implements MetadataProvider {
  AniListProvider({
    this.type = 'ANIME',
    this.includeAdult = false,
    http.Client? client,
    this.endpoint = _defaultEndpoint,
  }) : _client = client ?? createMetadataHttpClient();

  static const _defaultEndpoint = 'https://graphql.anilist.co';
  static const _query = r'''
query ($search: String!, $perPage: Int!, $type: MediaType!, $isAdult: Boolean) {
  Page(perPage: $perPage) {
    media(search: $search, type: $type, isAdult: $isAdult, sort: SEARCH_MATCH) {
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
      staff(perPage: 8) {
        edges { role node { name { full } image { large medium } } }
      }
      characters(perPage: 8, sort: ROLE) {
        edges {
          role
          node { name { full } image { large medium } }
          voiceActors(sort: RELEVANCE) {
            name { full }
            image { large medium }
            languageV2
          }
        }
      }
    }
  }
}
''';

  /// `ANIME` or `MANGA`. AniList's manga side carries manhwa and light
  /// novels too, which is where most of a Fundus manga shelf lives.
  final String type;
  final bool includeAdult;
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'anilist';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final response = await _request(
      () => _client.post(
        Uri.parse(endpoint),
        headers: const {
          'accept': 'application/json',
          'content-type': 'application/json',
          'user-agent': metadataUserAgent,
        },
        body: jsonEncode({
          'query': _query,
          'variables': {
            'search': normalizedQuery,
            'perPage': limit.clamp(1, 50),
            'type': type,
            'isAdult': includeAdult ? true : null,
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

  Future<http.Response> _request(Future<http.Response> Function() request) =>
      retryTransport(request, provider: provider);

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
      credits: _credits(value),
      externalIds: {'anilist': '${id.round()}'},
    );
  }

  /// Wer daran gearbeitet hat und wer die Rollen spricht.
  ///
  /// AniList führt zu beiden ein Bild — genau das, was eine Besetzungsseite
  /// braucht. Sprecher stehen mit ihrer Figur da („Sprecher · Denji"), denn
  /// ohne die Figur ist ein Sprechername nur ein Name.
  static List<MetadataPerson> _credits(Map value) {
    final people = <MetadataPerson>[];
    final seen = <String>{};

    void add(String name, String role, String? image) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) return;
      final key = '${trimmed.toLowerCase()}|$role';
      if (!seen.add(key)) return;
      people.add(MetadataPerson(name: trimmed, role: role, imageUrl: image));
    }

    final staff = value['staff'];
    final staffEdges = staff is Map ? staff['edges'] : null;
    if (staffEdges is List) {
      for (final edge in staffEdges) {
        if (edge is! Map) continue;
        final node = edge['node'];
        if (node is! Map) continue;
        final full = _stringFromMap(node['name'], 'full');
        if (full == null) continue;
        add(full, '${edge['role'] ?? 'Beteiligt'}', _portrait(node['image']));
      }
    }

    final characters = value['characters'];
    final characterEdges = characters is Map ? characters['edges'] : null;
    if (characterEdges is List) {
      for (final edge in characterEdges) {
        if (edge is! Map) continue;
        final node = edge['node'];
        final figure = node is Map
            ? _stringFromMap(node['name'], 'full')
            : null;
        final voices = edge['voiceActors'];
        if (voices is! List) continue;
        for (final voice in voices) {
          if (voice is! Map) continue;
          final full = _stringFromMap(voice['name'], 'full');
          if (full == null) continue;
          add(
            full,
            figure == null ? 'Sprecher' : 'Sprecher · $figure',
            _portrait(voice['image']),
          );
        }
      }
    }
    return people;
  }

  static String? _portrait(Object? image) =>
      _stringFromMap(image, 'large') ?? _stringFromMap(image, 'medium');

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
    : _client = client ?? createMetadataHttpClient();

  static const _endpoint = 'https://api.themoviedb.org/3/search/multi';
  final String apiKey;
  final http.Client _client;

  @override
  String get provider => 'tmdb';

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
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
        headers: const {
          'accept': 'application/json',
          'user-agent': metadataUserAgent,
        },
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
      throw MetadataProviderException(provider, _networkMessage(error));
    }
  }

  /// Wie breit ein Porträt geholt wird. 300 Pixel reichen für eine Kachel
  /// und für das Doppelte an Pixeldichte; das Original wären Megabyte pro
  /// Gesicht.
  static const _portraitBase = 'https://image.tmdb.org/t/p/w300';

  /// Wie viele Personen mitkommen.
  ///
  /// Eine Besetzungsliste ist manchmal hundert Namen lang; die ersten sind
  /// die, die jemand sucht, und jedes Bild ist eine Datei in der Bibliothek.
  static const _peopleLimit = 16;

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async {
    if (candidate.provider != provider || apiKey.trim().isEmpty) {
      return candidate;
    }
    final area = candidate.workKind == 'movie' ? 'movie' : 'tv';
    try {
      final response = await _request(
        _client.get(
          Uri.parse(
            'https://api.themoviedb.org/3/$area/${candidate.providerId}',
          ).replace(
            queryParameters: {
              'api_key': apiKey,
              'append_to_response': 'credits,external_ids',
            },
          ),
          headers: const {
            'accept': 'application/json',
            'user-agent': metadataUserAgent,
          },
        ),
      );
      final data = _decodeObject(response, provider);
      Map credits = data['credits'] is Map ? data['credits'] as Map : data;
      // Older or compatible endpoints may not implement append_to_response.
      if (credits['cast'] is! List && credits['crew'] is! List) {
        final fallback = await _request(
          _client.get(
            Uri.parse(
              'https://api.themoviedb.org/3/$area/${candidate.providerId}/credits',
            ).replace(queryParameters: {'api_key': apiKey}),
            headers: const {
              'accept': 'application/json',
              'user-agent': metadataUserAgent,
            },
          ),
        );
        credits = _decodeObject(fallback, provider);
      }
      final people = [
        ..._people(
          credits['cast'],
          roleKey: 'character',
          fallback: 'Darsteller',
        ),
        ..._people(credits['crew'], roleKey: 'job', fallback: 'Crew'),
      ];
      final genres = [
        for (final entry
            in data['genres'] is List ? data['genres'] as List : const [])
          if (entry is Map && entry['name'] is String) entry['name'] as String,
      ];
      final companies = [
        for (final entry
            in data['production_companies'] is List
                ? data['production_companies'] as List
                : const [])
          if (entry is Map && entry['name'] is String) entry['name'] as String,
        for (final entry
            in data['networks'] is List ? data['networks'] as List : const [])
          if (entry is Map && entry['name'] is String) entry['name'] as String,
      ];
      final ids = <String, String>{...candidate.externalIds};
      final external = data['external_ids'];
      if (external is Map && external['imdb_id'] is String) {
        ids['imdb'] = external['imdb_id'] as String;
      }
      return candidate.copyWith(
        genres: genres.isEmpty ? null : genres,
        publisher: companies.isEmpty ? null : companies.join(', '),
        series: data['belongs_to_collection'] is Map
            ? (data['belongs_to_collection'] as Map)['name'] as String?
            : null,
        episodeCount: (data['number_of_episodes'] as num?)?.round(),
        credits: people.isEmpty ? null : people.take(_peopleLimit).toList(),
        externalIds: ids,
      );
    } on MetadataProviderException {
      // Ohne Besetzung ist der Abgleich immer noch ein Abgleich.
      return candidate;
    }
  }

  static List<MetadataPerson> _people(
    Object? value, {
    required String roleKey,
    required String fallback,
  }) {
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map && entry['name'] is String)
          MetadataPerson(
            name: (entry['name']! as String).trim(),
            role: _roleLabel(
              roleKey == 'character'
                  ? 'Darsteller'
                  : (entry['department'] is String
                        ? entry['department'] as String
                        : fallback),
              entry[roleKey] is String ? entry[roleKey] as String : null,
            ),
            roleGroup: roleKey == 'character'
                ? 'Darsteller'
                : _crewGroup(entry['department'] as String?),
            imageUrl: entry['profile_path'] is String
                ? '$_portraitBase${entry['profile_path']}'
                : null,
          ),
    ];
  }

  static String _crewGroup(String? department) {
    final value = (department ?? '').toLowerCase();
    if (value.contains('direct')) return 'Regie';
    if (value.contains('writing') || value.contains('writer')) {
      return 'Drehbuch';
    }
    if (value.contains('production')) return 'Produktion';
    if (value.contains('camera') || value.contains('visual')) {
      return 'Kamera & Bild';
    }
    return department ?? 'Crew';
  }

  static String _roleLabel(String department, String? detail) {
    final label = department == 'Darsteller'
        ? 'Darsteller'
        : (detail ?? department);
    return department == 'Darsteller' &&
            detail != null &&
            detail.trim().isNotEmpty
        ? detail.trim()
        : label;
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

/// MyAnimeList über die offizielle Schnittstelle.
///
/// Der Weg über Jikan spiegelt MyAnimeList und ist deshalb nur so verfügbar
/// wie die Verbindung zwischen beiden. Die offizielle Schnittstelle braucht
/// dagegen eine Client-Kennung, die man sich kostenlos unter
/// `myanimelist.net/apiconfig` anlegt — kein OAuth, solange nur öffentliche
/// Angaben gelesen werden. Sie liegt wie der TMDB-Schlüssel ausschließlich im
/// geschützten Speicher des Geräts.
final class MyAnimeListApiProvider implements MetadataProvider {
  MyAnimeListApiProvider({
    required this.clientId,
    http.Client? client,
    this.includeAdult = false,
  }) : _client = client ?? createMetadataHttpClient();

  final http.Client _client;
  final String clientId;
  final bool includeAdult;

  static const _endpoint = 'api.myanimelist.net';

  /// Was beide Bestände kennen.
  static const _sharedFields =
      'id,title,alternative_titles,main_picture,start_date,synopsis,genres,'
      'media_type,status,nsfw';

  /// Anime und Manga haben getrennte Feldnamen, und die Schnittstelle weist
  /// eine Anfrage zurück, die Felder des jeweils anderen Bestands nennt.
  /// Eine gemeinsame Liste hätte deshalb beide Abfragen scheitern lassen.
  static String _fieldsFor(String kind) => kind == 'anime'
      ? '$_sharedFields,num_episodes,studios'
      : '$_sharedFields,num_volumes,num_chapters,authors{first_name,last_name}';

  @override
  String get provider => 'myanimelist';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    if (clientId.trim().isEmpty) {
      throw MetadataProviderException(
        provider,
        'Für MyAnimeList fehlt die Client-ID. '
        'Sie lässt sich kostenlos unter myanimelist.net/apiconfig anlegen '
        'und wird in den Einstellungen hinterlegt.',
      );
    }
    // Anime und Manga sind getrennte Bestände. Fällt einer aus, darf das den
    // anderen nicht verwerfen.
    final found = <MetadataCandidate>[];
    MetadataProviderException? firstFailure;
    for (final kind in const ['anime', 'manga']) {
      try {
        final response = await retryTransport(
          () => _client.get(
            Uri.https(_endpoint, '/v2/$kind', {
              'q': q,
              'limit': '${limit.clamp(1, 100)}',
              'fields': _fieldsFor(kind),
              if (includeAdult) 'nsfw': 'true',
            }),
            headers: {
              'accept': 'application/json',
              'user-agent': metadataUserAgent,
              'X-MAL-CLIENT-ID': clientId.trim(),
            },
          ),
          provider: provider,
        );
        final decoded = _decodeObject(response, provider);
        if (decoded['data'] case final List data) {
          for (final entry in data) {
            if (entry is Map && entry['node'] is Map) {
              final candidate = _candidate(entry['node'] as Map, kind: kind);
              if (candidate != null) found.add(candidate);
            }
          }
        }
      } on MetadataProviderException catch (error) {
        firstFailure ??= error;
      }
    }
    if (found.isEmpty && firstFailure != null) throw firstFailure;
    return found;
  }

  MetadataCandidate? _candidate(Map node, {required String kind}) {
    final id = node['id'];
    final title = node['title'];
    if (id is! num || title is! String || title.trim().isEmpty) return null;

    final alternates = <String>[];
    if (node['alternative_titles'] case final Map other) {
      for (final key in const ['en', 'ja']) {
        final value = other[key];
        if (value is String && value.trim().isNotEmpty) {
          alternates.add(value.trim());
        }
      }
      if (other['synonyms'] case final List synonyms) {
        for (final entry in synonyms) {
          if (entry is String && entry.trim().isNotEmpty) {
            alternates.add(entry.trim());
          }
        }
      }
    }

    final nsfw = '${node['nsfw'] ?? ''}';
    // `white` ist unbedenklich, `gray` grenzwertig, `black` ausdrücklich.
    final adult = nsfw == 'black';

    return MetadataCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title.trim(),
      alternateTitles: alternates,
      workKind: kind == 'anime' ? 'anime' : 'manga',
      authors: [
        if (node['authors'] case final List authors)
          for (final author in authors)
            if (author is Map && author['node'] is Map)
              ?_personName(author['node'] as Map),
      ],
      releaseYear: _yearFrom('${node['start_date'] ?? ''}'),
      episodeCount: switch (node['num_episodes']) {
        final num count when count > 0 => count.round(),
        _ => null,
      },
      description: _firstString([node['synopsis']]),
      contentSensitivity: adult ? 'adult_explicit' : null,
      isAdult: adult,
      genres: [
        if (node['genres'] case final List genres)
          for (final genre in genres)
            if (genre is Map) ?_firstString([genre['name']]),
      ],
      posterUrl: switch (node['main_picture']) {
        final Map picture => _firstString([
          picture['large'],
          picture['medium'],
        ]),
        _ => null,
      },
      externalIds: {'mal': '${id.round()}'},
    );
  }

  static String? _personName(Map node) {
    final parts = [
      '${node['first_name'] ?? ''}'.trim(),
      '${node['last_name'] ?? ''}'.trim(),
    ].where((part) => part.isNotEmpty);
    final name = parts.join(' ').trim();
    return name.isEmpty ? null : name;
  }

  static int? _yearFrom(String value) =>
      value.length >= 4 ? int.tryParse(value.substring(0, 4)) : null;
}

/// MangaDex — die Brücke zwischen Titel und Kennung.
///
/// Der eigentliche Wert liegt nicht in den Metadaten, sondern im Feld `links`:
/// MangaDex führt zu fast jedem Eintrag die AniList- und MyAnimeList-Kennung
/// mit. Damit wird aus einer unscharfen Titelsuche eine exakte Auflösung — man
/// sucht einmal nach dem Namen und fragt die anderen Dienste danach über ihre
/// eigene Kennung, statt jeden von ihnen erneut raten zu lassen.
///
/// Ohne Anmeldung, ohne Schlüssel. Nicht jugendfreie Einträge sind
/// ausgeblendet, solange sie nicht ausdrücklich angefordert werden.
final class MangaDexProvider implements MetadataProvider {
  MangaDexProvider({http.Client? client, this.includeAdult = false})
    : _client = client ?? createMetadataHttpClient();

  final http.Client _client;
  final bool includeAdult;

  static const _endpoint = 'api.mangadex.org';

  @override
  String get provider => 'mangadex';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final response = await retryTransport(
      () => _client.get(
        Uri.https(_endpoint, '/manga', {
          'title': q,
          'limit': '${limit.clamp(1, 100)}',
          'contentRating[]': includeAdult
              ? const ['safe', 'suggestive', 'erotica', 'pornographic']
              : const ['safe', 'suggestive'],
          'order[relevance]': 'desc',
        }),
        headers: const {
          'accept': 'application/json',
          'user-agent': metadataUserAgent,
        },
      ),
      provider: provider,
    );
    final decoded = _decodeObject(response, provider);
    if (decoded['data'] case final List data) {
      return [
        for (final item in data)
          if (item is Map) ?_candidate(item, language: language),
      ];
    }
    return const [];
  }

  MetadataCandidate? _candidate(Map value, {String? language}) {
    final id = value['id'];
    final attributes = value['attributes'];
    if (id is! String || attributes is! Map) return null;

    // Titel kommen als Sprachkarte. Bevorzugt wird die Sprache der Oberfläche,
    // dann Englisch, dann was da ist — und alles Übrige bleibt als
    // Alternativtitel erhalten, weil danach gesucht worden sein kann.
    final preferred = (language ?? 'de').split('-').first.toLowerCase();
    final titles = <String>[];
    void collect(Object? source) {
      if (source is Map) {
        for (final entry in source.entries) {
          final text = entry.value;
          if (text is String && text.trim().isNotEmpty) titles.add(text.trim());
        }
      }
    }

    final primary = attributes['title'];
    String? pick(String code) => primary is Map && primary[code] is String
        ? (primary[code] as String).trim()
        : null;
    final title = pick(preferred) ?? pick('en') ?? pick('ja-ro');
    collect(primary);
    if (attributes['altTitles'] case final List alternates) {
      for (final entry in alternates) {
        collect(entry);
      }
    }
    final chosen = title ?? titles.firstOrNull;
    if (chosen == null || chosen.isEmpty) return null;

    final links = attributes['links'];
    String? link(String key) =>
        links is Map &&
            links[key] is String &&
            (links[key] as String).trim().isNotEmpty
        ? (links[key] as String).trim()
        : null;

    final rating = '${attributes['contentRating'] ?? ''}';
    final adult = rating == 'pornographic' || rating == 'erotica';

    return MetadataCandidate(
      provider: provider,
      providerId: id,
      title: chosen,
      alternateTitles: titles.where((entry) => entry != chosen).toList(),
      workKind: 'manga',
      contentStyle: switch ('${attributes['originalLanguage'] ?? ''}') {
        'ko' => 'manhwa',
        'zh' || 'zh-hk' => 'manhua',
        _ => 'manga',
      },
      contentSensitivity: adult ? 'adult_explicit' : null,
      isAdult: adult,
      releaseYear: attributes['year'] is num
          ? (attributes['year'] as num).round()
          : null,
      description: switch (attributes['description']) {
        final Map description => _firstString([
          description[preferred],
          description['en'],
        ]),
        _ => null,
      },
      genres: [
        if (attributes['tags'] case final List tags)
          for (final tag in tags)
            if (tag is Map && tag['attributes'] is Map)
              if ((tag['attributes'] as Map)['name'] case final Map names)
                ?_firstString([names['en']]),
      ],
      // Das eigentliche Ergebnis: die Kennungen der anderen Dienste.
      externalIds: {
        'mangadex': id,
        'anilist': ?link('al'),
        'mal': ?link('mal'),
        'raw': ?link('raw'),
        'engtl': ?link('engtl'),
      },
    );
  }
}

/// MyAnimeList through the public Jikan API, without account or secret.
///
/// Jikan spiegelt MyAnimeList und ist deshalb nur so verfügbar wie die
/// Verbindung zwischen beiden: fällt sie aus, antwortet Jikan mit HTTP 504,
/// und zwar sofort statt nach einer Zeitüberschreitung. Daran ändert kein
/// Wiederholen etwas. `includeAdult` steuert hier nur noch, wie ein Treffer
/// gekennzeichnet wird — gefiltert wird nicht mehr beim Anbieter.
final class MyAnimeListProvider implements MetadataProvider {
  MyAnimeListProvider({http.Client? client, this.includeAdult = false})
    : _client = client ?? createMetadataHttpClient();

  final http.Client _client;
  final bool includeAdult;

  @override
  String get provider => 'myanimelist';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Jikan rate-limits anime and manga independently. One 429 or transient
    // failure must not discard valid results from the other catalogue.
    final responses = <({String kind, http.Response response})>[];
    MetadataProviderException? firstFailure;
    for (final kind in const ['anime', 'manga']) {
      try {
        final response = await _request(
          () => _client.get(
            // `sfw=true` entfernte alles mit Ecchi-Kennzeichnung — darunter
            // viele gewöhnliche Manga, die dadurch unauffindbar waren. Was
            // geschützt gehört, entscheidet der Schutzmodus anhand des Werks,
            // nicht eine Vorauswahl beim Anbieter.
            Uri.https('api.jikan.moe', '/v4/$kind', {
              'q': q,
              'limit': '${limit.clamp(1, 25)}',
            }),
            headers: const {
              'accept': 'application/json',
              'user-agent': metadataUserAgent,
            },
          ),
        );
        _decodeObject(response, provider);
        responses.add((kind: kind, response: response));
      } on MetadataProviderException catch (error) {
        firstFailure ??= error;
      }
    }
    if (responses.isEmpty && firstFailure != null) throw firstFailure;
    return [
      for (final entry in responses)
        if (_decodeObject(entry.response, provider)['data']
            case final List data)
          for (final item in data)
            if (item is Map) ?_candidate(item, kind: entry.kind, query: q),
    ];
  }

  Future<http.Response> _request(Future<http.Response> Function() request) =>
      retryTransport(request, provider: provider);

  MetadataCandidate? _candidate(
    Map value, {
    required String kind,
    String? query,
  }) {
    final id = value['mal_id'];
    final titleOptions = [
      value['title'],
      value['title_english'],
      value['title_japanese'],
    ];
    final normalizedQuery = query?.trim().toLowerCase();
    final title = normalizedQuery == null || normalizedQuery.isEmpty
        ? _firstString(titleOptions)
        : _firstString([
            for (final option in titleOptions)
              if (option is String &&
                  option.toLowerCase().contains(normalizedQuery))
                option,
            ...titleOptions,
          ]);
    if (id is! num || title == null) return null;
    final type = '${value['type'] ?? ''}'.toLowerCase();
    final images = value['images'];
    final jpg = images is Map ? images['jpg'] : null;
    final image = jpg is Map
        ? _firstString([jpg['large_image_url'], jpg['image_url']])
        : null;
    final published = value['published'];
    final from = published is Map ? published['from'] : null;
    final year = from is String
        ? int.tryParse(from.substring(0, from.length.clamp(0, 4)))
        : null;
    final titles = <String>{
      for (final raw in [
        value['title'],
        value['title_english'],
        value['title_japanese'],
        ...(value['titles'] is List ? value['titles'] as List : const []),
      ])
        if (raw is String && raw.trim().isNotEmpty)
          raw.trim()
        else if (raw is Map && raw['title'] is String)
          (raw['title'] as String).trim(),
    }..remove(title);
    final genres = <String>[
      for (final raw in [
        ...(value['genres'] is List ? value['genres'] as List : const []),
        ...(value['themes'] is List ? value['themes'] as List : const []),
      ])
        if (raw is Map && raw['name'] is String) raw['name'] as String,
    ];
    final authors = <String>[
      for (final raw
          in value['authors'] is List ? value['authors'] as List : const [])
        if (raw is Map && raw['name'] is String) raw['name'] as String,
    ];
    return MetadataCandidate(
      provider: provider,
      providerId: '$id',
      title: title,
      alternateTitles: titles.toList(growable: false),
      authors: authors,
      workKind: kind == 'anime'
          ? 'anime'
          : type.contains('light novel') || type == 'novel'
          ? 'novel'
          : 'manga',
      contentStyle: 'anime',
      contentSensitivity: includeAdult ? 'adult_explicit' : null,
      releaseYear: year,
      isAdult: includeAdult,
      description: _cleanDescription(value['synopsis']),
      language: 'ja',
      genres: genres,
      posterUrl: image,
      externalIds: {'mal': '$id'},
    );
  }
}

/// Hardcover's public GraphQL catalogue for books, novels and series.
///
/// The search endpoint returns stable book ids; a second query resolves those
/// ids into the fields Fundus can actually store. This avoids depending on
/// the search result JSON shape, which is intentionally an opaque `jsonb`
/// field in Hardcover's schema.
final class HardcoverProvider implements MetadataProvider {
  HardcoverProvider({
    required String token,
    http.Client? client,
    this.endpoint = _defaultEndpoint,
  }) : _token = token.trim(),
       _client = client ?? createMetadataHttpClient();

  static const _defaultEndpoint = 'https://api.hardcover.app/v1/graphql';
  static const _searchQuery = r'''
query Search($query: String!, $limit: Int!) {
  search(query: $query, query_type: "book", per_page: $limit) {
    ids
    results
  }
}
''';
  static const _booksQuery = r'''
query Books($ids: [Int!]!) {
  books(where: {id: {_in: $ids}}) {
    id
    title
    subtitle
    description
    release_year
    release_date
    pages
    image { url }
    cached_image
    contributions { contribution author { name } }
    book_series { position series { name } }
  }
}
''';

  final String _token;
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'hardcover';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
    String? language,
  }) async {
    if (_token.isEmpty) {
      throw const MetadataProviderException(
        'hardcover',
        'Hardcover-API-Token fehlt. Hinterlege ihn in den Einstellungen.',
      );
    }
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final search = await _request(_searchQuery, {
      'query': normalized,
      'limit': limit.clamp(1, 25),
    });
    final payload = _object(search['data']);
    final result = _object(payload?['search']);
    final ids = <int>{
      for (final id
          in result?['ids'] is List ? result!['ids'] as List : const [])
        if (id is num) id.round(),
    };
    if (ids.isEmpty) return _candidatesFromSearchJson(result?['results']);
    final books = await _request(_booksQuery, {'ids': ids.toList()});
    final data = _object(books['data']);
    final values = data?['books'];
    if (values is! List) return const [];
    return [
      for (final value in values)
        if (value is Map) ?_candidate(value, language: language),
    ];
  }

  Future<Map<String, Object?>> _request(
    String query,
    Map<String, Object?> variables,
  ) async {
    try {
      final response = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'accept': 'application/json',
              'content-type': 'application/json',
              'authorization': 'Bearer $_token',
              'user-agent': metadataUserAgent,
            },
            body: jsonEncode({'query': query, 'variables': variables}),
          )
          .timeout(const Duration(seconds: 15));
      return _decodeObject(response, provider);
    } on TimeoutException {
      throw MetadataProviderException(provider, 'Zeitüberschreitung');
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      throw MetadataProviderException(provider, _networkMessage(error));
    }
  }

  MetadataCandidate? _candidate(Map value, {String? language}) {
    final id = value['id'];
    final title = _firstString([value['title'], value['subtitle']]);
    if (id is! num || title == null) return null;
    final series = value['book_series'];
    final firstSeries = series is List && series.isNotEmpty
        ? series.first
        : null;
    final seriesMap = firstSeries is Map ? firstSeries['series'] : null;
    final seriesName = seriesMap is Map
        ? _firstString([seriesMap['name']])
        : null;
    final position = firstSeries is Map
        ? (firstSeries['position'] as num?)?.toDouble()
        : null;
    final image = value['image'];
    final cachedImage = value['cached_image'];
    final poster = _firstString([
      image is Map ? image['url'] : null,
      cachedImage is Map ? cachedImage['url'] : null,
    ]);
    final contributions = value['contributions'];
    final authors = <String>[];
    if (contributions is List) {
      for (final contribution in contributions) {
        if (contribution is! Map) continue;
        final author = contribution['author'];
        final name = author is Map ? _firstString([author['name']]) : null;
        if (name != null && !authors.contains(name)) authors.add(name);
      }
    }
    final year =
        (value['release_year'] as num?)?.round() ??
        _year(value['release_date']);
    return MetadataCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      alternateTitles: [
        if (value['subtitle'] is String && value['subtitle'] != title)
          value['subtitle'] as String,
      ],
      authors: authors,
      workKind: 'novel',
      series: seriesName,
      seriesSequence: position,
      releaseYear: year,
      description: _cleanDescription(value['description']),
      posterUrl: poster,
      externalIds: {'hardcover': '${id.round()}'},
    );
  }

  List<MetadataCandidate> _candidatesFromSearchJson(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final value in raw)
        if (value is Map) ?_candidate(value),
    ];
  }

  static Map<String, Object?>? _object(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : null;

  static int? _year(Object? value) {
    if (value is! String || value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
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
    : _client = client ?? createMetadataHttpClient();

  static const _defaultEndpoint = 'https://openlibrary.org/search.json';
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'openlibrary';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
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
        headers: const {
          'accept': 'application/json',
          'user-agent': metadataUserAgent,
        },
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
      throw MetadataProviderException(provider, _networkMessage(error));
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
    : _client = client ?? createMetadataHttpClient();

  final http.Client _client;

  /// Overrides the shop derived from the language. Tests set it; nothing else
  /// needs to.
  final String? host;

  @override
  String get provider => 'audible';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

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
    int limit = 25,
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
        headers: const {
          'accept': 'application/json',
          'user-agent': metadataUserAgent,
        },
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
      throw MetadataProviderException(provider, _networkMessage(error));
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
    : _client = client ?? createMetadataHttpClient();

  static const _defaultEndpoint = 'https://itunes.apple.com/search';
  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'apple_podcasts';

  @override
  Future<MetadataCandidate> enrich(MetadataCandidate candidate) async =>
      candidate;

  @override
  Future<List<MetadataCandidate>> search(
    String query, {
    int limit = 25,
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
        headers: const {
          'accept': 'application/json',
          'user-agent': metadataUserAgent,
        },
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
      throw MetadataProviderException(provider, _networkMessage(error));
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

/// Reads a JSON body as UTF-8, whatever the service forgot to declare.
///
/// `http` falls back to latin1 when the `content-type` carries no charset, and
/// several of these services send bare `application/json`. Every Japanese
/// title and every umlaut then arrives as mojibake — before the ranking gets
/// to compare it with the query, which is where it does the real damage.
String _decodeBody(http.Response response) {
  try {
    return utf8.decode(response.bodyBytes);
  } on FormatException {
    // Not valid UTF-8 after all: fall back rather than lose the body.
    return response.body;
  }
}

/// Wiederholt eine Abfrage, die vorübergehend gescheitert sein kann.
///
/// Zwei Arten von Fehlschlag sehen für den Aufrufer gleich aus und wurden
/// bisher verschieden behandelt: eine Antwort mit 429 oder 5xx wurde
/// wiederholt, ein *geworfener* Fehler — Zeitüberschreitung, abgerissene
/// Verbindung, WinHTTP — verließ die Schleife beim ersten Versuch. Gerade der
/// zweite Fall ist aber der, bei dem ein zweiter Versuch hilft.
///
/// Die Wartezeit beginnt bei einer Sekunde. Darunter liegt sie innerhalb des
/// Ratenfensters der Dienste, und ein Wiederholen im selben Fenster ist kein
/// Wiederholen, sondern ein zweiter Verstoß.
Future<http.Response> retryTransport(
  Future<http.Response> Function() request, {
  required String provider,
  int attempts = 3,
}) async {
  Object? lastError;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
    }
    try {
      final response = await request().timeout(const Duration(seconds: 12));
      if (response.statusCode != 429 && response.statusCode < 500) {
        return response;
      }
      // Der letzte Durchgang gibt die Antwort heraus: ihr Status sagt mehr
      // als ein selbst formulierter Netzwerkfehler.
      if (attempt == attempts - 1) return response;
      lastError = null;
    } on MetadataProviderException {
      rethrow;
    } on Object catch (error) {
      lastError = error;
    }
  }
  throw switch (lastError) {
    TimeoutException() => MetadataProviderException(
      provider,
      'Zeitüberschreitung',
    ),
    final Object error => MetadataProviderException(
      provider,
      _networkMessage(error),
    ),
    null => MetadataProviderException(provider, 'Die Abfrage ist gescheitert.'),
  };
}

Map<String, Object?> _decodeObject(http.Response response, String provider) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    var detail = 'HTTP ${response.statusCode}';
    try {
      final decoded = jsonDecode(_decodeBody(response));
      // Services disagree on where they put the reason: Jikan uses `message`
      // for some failures and `error` for others. Saying „HTTP 504" alone
      // hides that the fault is upstream of us.
      final reason = _firstString([
        if (decoded is Map) ...[decoded['message'], decoded['error']],
      ]);
      if (reason != null) detail = '$detail: $reason';
    } on Object {
      // Keep the status useful even when a proxy returned HTML/plain text.
    }
    throw MetadataProviderException(
      provider,
      'Der Dienst hat mit einem Fehler geantwortet ($detail).',
    );
  }
  try {
    final decoded = jsonDecode(_decodeBody(response));
    if (decoded is! Map) throw const FormatException();
    if (decoded['errors'] is List && (decoded['errors'] as List).isNotEmpty) {
      final first = (decoded['errors'] as List).first;
      final message = first is Map && first['message'] is String
          ? (first['message'] as String).trim()
          : 'Die Antwort ist ungültig.';
      throw MetadataProviderException(provider, message);
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
