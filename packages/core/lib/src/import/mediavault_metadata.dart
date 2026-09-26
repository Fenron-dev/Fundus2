import 'dart:io';

import 'package:yaml/yaml.dart';

/// Metadata written by Fero/MediaVault beside a publication.
///
/// The source stays read-only. Fundus imports its useful fields into the
/// portable catalogue and keeps its own `_fundus/meta.yaml` as the authority
/// for later manual edits.
final class MediaVaultMetadata {
  const MediaVaultMetadata({
    this.title,
    this.authors = const [],
    this.subtitle,
    this.alternateTitles = const [],
    this.description,
    this.series,
    this.sequence,
    this.language,
    this.publisher,
    this.publishedYear,
    this.publicationStatus,
    this.coverPath,
    this.notes,
    this.tags = const [],
    this.genres = const [],
    this.externalRating,
  });

  final String? title;
  final List<String> authors;
  final String? subtitle;
  final List<String> alternateTitles;
  final String? description;
  final String? series;
  final double? sequence;
  final String? language;
  final String? publisher;
  final int? publishedYear;
  final String? publicationStatus;
  final String? coverPath;
  final String? notes;
  final List<String> tags;
  final List<String> genres;
  final double? externalRating;

  Map<String, Object?> toDatabaseMetadata() => {
    if (authors.isNotEmpty) 'author': authors.first,
    if (authors.isNotEmpty) 'authors': authors,
    if (subtitle != null) 'subtitle': subtitle,
    if (alternateTitles.isNotEmpty) 'alternate_titles': alternateTitles,
    if (description != null) 'description': description,
    if (series != null) 'series': series,
    if (sequence != null) 'series_sequence': sequence,
    if (language != null) 'language': language,
    if (publisher != null) 'publisher': publisher,
    if (publishedYear != null) 'published_year': publishedYear,
    if (genres.isNotEmpty) 'genres': genres,
  };
}

final class MediaVaultMetadataReader {
  const MediaVaultMetadataReader();

  static const maximumBytes = 2 * 1024 * 1024;

  Future<MediaVaultMetadata?> read(File file) async {
    if (!await file.exists() || await file.length() > maximumBytes) return null;
    final decoded = loadYaml(await file.readAsString());
    if (decoded is! Map) return null;
    final authors = <String>{
      ..._strings(decoded['authors']),
      ?_string(decoded['author']),
    }.toList(growable: false);
    return MediaVaultMetadata(
      title: _string(decoded['title']),
      authors: authors,
      subtitle: _string(decoded['subtitle']),
      alternateTitles: {
        ..._strings(decoded['alternate_titles']),
        ..._strings(decoded['synonyms']),
      }.toList(growable: false),
      description: _string(decoded['description'], maximumLength: 50000),
      series: _string(decoded['series_title'] ?? decoded['series']),
      sequence: _number(
        decoded['series_sequence'] ?? decoded['volume'] ?? decoded['sequence'],
      ),
      language: _string(decoded['language']),
      publisher: _string(decoded['publisher']),
      publishedYear: _integer(
        decoded['published_year'] ?? decoded['year'] ?? decoded['release_year'],
      ),
      publicationStatus: _publicationStatus(decoded['status']),
      coverPath: _string(decoded['cover_path']),
      notes: _string(decoded['notes'], maximumLength: 50000),
      tags: _strings(decoded['tags']),
      genres: _strings(decoded['genres']),
      externalRating: _number(
        decoded['rating_external'] ?? decoded['external_rating'],
      ),
    );
  }

  static String? _publicationStatus(Object? value) {
    final normalized = _string(value)?.toLowerCase().replaceAll('_', '-');
    return switch (normalized) {
      'ongoing' || 'serializing' || 'publishing' => 'ongoing',
      'completed' || 'complete' || 'finished' => 'completed',
      'paused' => 'paused',
      'hiatus' || 'on-hiatus' => 'hiatus',
      'cancelled' || 'canceled' || 'dropped' => 'cancelled',
      // Fero's `in-library` says where the file is, not whether its story is
      // still being published. Treating it as ongoing would invent data.
      _ => null,
    };
  }

  static String? _string(Object? value, {int maximumLength = 1000}) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    return normalized.length <= maximumLength
        ? normalized
        : normalized.substring(0, maximumLength);
  }

  static List<String> _strings(Object? value) {
    if (value is String) {
      return value
          .split(',')
          .map(_string)
          .whereType<String>()
          .toSet()
          .toList(growable: false);
    }
    if (value is! List) return const [];
    return value
        .take(200)
        .map(_string)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
  }

  static double? _number(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) {
      return double.tryParse(value.trim().replaceAll(',', '.'));
    }
    return null;
  }

  static int? _integer(Object? value) {
    final number = _number(value);
    return number?.round();
  }
}
