/// Provider-neutral metadata for any kind of work.
///
/// The core package deliberately contains no HTTP client and no credentials.
/// An adapter — AniList, TMDB, Open Library — maps whatever its service
/// answers onto these fields, and only these fields and the provider's own id
/// are ever written into a vault. What a service calls a „format", a „media
/// type" or a „doc" is its business; a Fundus work has a title, people who
/// made it, a place in a series and a picture.
final class MetadataCandidate {
  const MetadataCandidate({
    required this.provider,
    required this.providerId,
    required this.title,
    this.alternateTitles = const [],
    this.authors = const [],
    this.workKind,
    this.series,
    this.seriesSequence,
    this.contentStyle,
    this.contentSensitivity,
    this.releaseYear,
    this.season,
    this.episodeCount,
    this.isAdult,
    this.description,
    this.publisher,
    this.language,
    this.genres = const [],
    this.posterUrl,
    this.backdropUrl,
    this.externalIds = const {},
  });

  /// Which service answered — `anilist`, `tmdb`, `openlibrary`.
  final String provider;
  final String providerId;
  final String title;
  final List<String> alternateTitles;

  /// Who made it: authors for a book, the writer for a manga, absent where a
  /// service does not say.
  final List<String> authors;

  /// What Fundus would call it — `movie`, `tv`, `manga`, `ebook`, `audiobook`.
  final String? workKind;

  final String? series;
  final double? seriesSequence;

  final String? contentStyle;
  final String? contentSensitivity;
  final int? releaseYear;
  final int? season;
  final int? episodeCount;
  final bool? isAdult;
  final String? description;
  final String? publisher;
  final String? language;
  final List<String> genres;
  final String? posterUrl;
  final String? backdropUrl;
  final Map<String, String> externalIds;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'provider_id': providerId,
    'title': title,
    if (alternateTitles.isNotEmpty) 'alternate_titles': alternateTitles,
    if (authors.isNotEmpty) 'authors': authors,
    if (workKind != null) 'work_kind': workKind,
    if (series != null) 'series': series,
    if (seriesSequence != null) 'series_sequence': seriesSequence,
    if (contentStyle != null) 'content_style': contentStyle,
    if (contentSensitivity != null) 'content_sensitivity': contentSensitivity,
    if (releaseYear != null) 'release_year': releaseYear,
    if (season != null) 'season': season,
    if (episodeCount != null) 'episode_count': episodeCount,
    if (isAdult != null) 'is_adult': isAdult,
    if (description != null) 'description': description,
    if (publisher != null) 'publisher': publisher,
    if (language != null) 'language': language,
    if (genres.isNotEmpty) 'genres': genres,
    if (posterUrl != null) 'poster_url': posterUrl,
    if (backdropUrl != null) 'backdrop_url': backdropUrl,
    if (externalIds.isNotEmpty) 'external_ids': externalIds,
  };

  static MetadataCandidate? fromJson(Object? value) {
    if (value is! Map ||
        value['provider'] is! String ||
        value['provider_id'] is! String ||
        value['title'] is! String) {
      return null;
    }
    List<String> strings(Object? raw) => raw is List
        ? raw.whereType<String>().toList(growable: false)
        : const [];
    final externalIds = value['external_ids'];
    return MetadataCandidate(
      provider: value['provider'] as String,
      providerId: value['provider_id'] as String,
      title: value['title'] as String,
      alternateTitles: strings(value['alternate_titles']),
      authors: strings(value['authors']),
      workKind: value['work_kind'] as String?,
      series: value['series'] as String?,
      seriesSequence: (value['series_sequence'] as num?)?.toDouble(),
      contentStyle: value['content_style'] as String?,
      contentSensitivity: value['content_sensitivity'] as String?,
      releaseYear: (value['release_year'] as num?)?.round(),
      season: (value['season'] as num?)?.round(),
      episodeCount: (value['episode_count'] as num?)?.round(),
      isAdult: value['is_adult'] as bool?,
      description: value['description'] as String?,
      publisher: value['publisher'] as String?,
      language: value['language'] as String?,
      genres: strings(value['genres']),
      posterUrl: value['poster_url'] as String?,
      backdropUrl: value['backdrop_url'] as String?,
      externalIds: externalIds is Map
          ? {
              for (final entry in externalIds.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : const {},
    );
  }
}

final class MetadataMatch {
  const MetadataMatch({
    required this.candidate,
    required this.score,
    this.reasons = const [],
  });

  final MetadataCandidate candidate;
  final double score;
  final List<String> reasons;

  /// Below this a match is a suggestion, not an answer.
  ///
  /// Anything less certain is offered rather than applied: a folder named
  /// after a fan group matches half a dozen things weakly, and quietly
  /// picking one of them is how a library fills up with wrong covers.
  bool get needsConfirmation => score < .92;
}

/// Ranks candidates locally, so a network adapter stays simple and a person
/// can see why a match was suggested.
List<MetadataMatch> rankMetadataCandidates(
  String query,
  Iterable<MetadataCandidate> candidates, {
  int? year,
}) {
  final normalizedQuery = normalizeWorkTitle(query);
  if (normalizedQuery.isEmpty) return const [];
  final queryTokens = normalizedQuery.split(' ').toSet();
  final matches = <MetadataMatch>[];
  for (final candidate in candidates) {
    final titles = [candidate.title, ...candidate.alternateTitles]
        .map(normalizeWorkTitle)
        .where((title) => title.isNotEmpty)
        .toList(growable: false);
    var bestScore = 0.0;
    var bestTitle = candidate.title;
    for (final title in titles) {
      final titleTokens = title.split(' ').toSet();
      final overlap = queryTokens.intersection(titleTokens).length;
      final tokenScore = overlap / queryTokens.length;
      final score = title == normalizedQuery
          ? 1.0
          : title.startsWith(normalizedQuery) ||
                normalizedQuery.startsWith(title)
          ? .9
          : tokenScore * .8;
      if (score > bestScore) {
        bestScore = score;
        bestTitle = title;
      }
    }
    if (bestScore <= 0) continue;
    // A year that is known on both sides is the cheapest way to separate a
    // remake from what it remade.
    final sameYear = year != null && candidate.releaseYear == year;
    final wrongYear =
        year != null &&
        candidate.releaseYear != null &&
        candidate.releaseYear != year;
    final adjusted =
        (sameYear
                ? bestScore + .08
                : wrongYear
                ? bestScore - .15
                : bestScore)
            .clamp(0.0, 1.0)
            .toDouble();
    matches.add(
      MetadataMatch(
        candidate: candidate,
        score: adjusted,
        reasons: [
          if (bestTitle == normalizedQuery) 'Exakter Titel',
          if (bestTitle != normalizedQuery && bestScore >= .9) 'Titelpräfix',
          if (bestScore < .9) 'Gemeinsame Titelwörter',
          if (sameYear) 'Gleiches Jahr',
          if (wrongYear) 'Anderes Jahr',
        ],
      ),
    );
  }
  matches.sort((left, right) {
    final score = right.score.compareTo(left.score);
    if (score != 0) return score;
    return left.candidate.title.toLowerCase().compareTo(
      right.candidate.title.toLowerCase(),
    );
  });
  return matches;
}

/// Titles as they compare: no case, no punctuation, no double spaces.
String normalizeWorkTitle(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[._:/\\-]+'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
