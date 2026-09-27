import 'dart:convert';
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
    this.sourceLinks = const {},
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
  final Map<String, String> sourceLinks;

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
    if (tags.isNotEmpty) 'tags': tags,
    if (genres.isNotEmpty) 'genres': genres,
    if (sourceLinks.isNotEmpty) 'external_ids': sourceLinks,
  };
}

final class MediaVaultMetadataReader {
  const MediaVaultMetadataReader();

  static const maximumBytes = 2 * 1024 * 1024;

  Future<MediaVaultMetadata?> read(File file) async {
    if (!await file.exists() || await file.length() > maximumBytes) return null;
    final text = await file.readAsString();
    Object? decoded;
    if (file.path.toLowerCase().endsWith('.json')) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        return null;
      }
    } else {
      decoded = loadYaml(text);
    }
    if (decoded is! Map) return null;
    // Recent Fero exports wrap publication data below `work` or `metadata`.
    // Flatten maps so both that envelope and the old flat YAML use one parser.
    final values = <Object?, Object?>{};
    void collect(Map<Object?, Object?> map) {
      for (final entry in map.entries) {
        values.putIfAbsent(entry.key, () => entry.value);
        if (entry.value is Map) {
          collect(Map<Object?, Object?>.from(entry.value as Map));
        }
      }
    }

    collect(Map<Object?, Object?>.from(decoded));
    Object? value(String key) =>
        values[key] ?? values[key.replaceAll('_', '-')];
    final authors = <String>{
      ..._strings(value('authors')),
      ?_string(value('author')),
      ..._strings(value('creators')),
    }.toList(growable: false);
    final notes = _string(value('notes'), maximumLength: 50000);
    final sourceLinks = _sourceLinks(
      notes,
      value('source_links') ??
          value('external_links') ??
          value('links') ??
          value('sources') ??
          value('source_url') ??
          value('source'),
    );
    return MediaVaultMetadata(
      title: _string(value('title') ?? value('name')),
      authors: authors,
      subtitle: _string(value('subtitle')),
      alternateTitles: {
        ..._strings(value('alternate_titles')),
        ..._strings(value('synonyms')),
      }.toList(growable: false),
      description: _string(value('description'), maximumLength: 50000),
      series: _string(value('series_title') ?? value('series')),
      sequence: _number(
        value('series_sequence') ?? value('volume') ?? value('sequence'),
      ),
      language: _string(value('language')),
      publisher: _string(value('publisher')),
      publishedYear: _integer(
        value('published_year') ?? value('year') ?? value('release_year'),
      ),
      publicationStatus: _publicationStatus(value('status')),
      coverPath: _string(value('cover_path') ?? value('cover')),
      notes: notes,
      tags: {
        ..._strings(value('tags')),
        ..._strings(value('keywords')),
      }.toList(growable: false),
      genres: {
        ..._strings(value('genres')),
        ..._strings(value('genre')),
      }.toList(growable: false),
      externalRating: _number(
        value('rating_external') ?? value('external_rating') ?? value('rating'),
      ),
      sourceLinks: sourceLinks,
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

  static Map<String, String> _sourceLinks(String? notes, [Object? raw]) {
    final links = <String, String>{};
    final text = [if (notes != null) notes, ..._flattenText(raw)].join(' ');
    final urls = RegExp(r'https?://[^\s<>"“”]+', caseSensitive: false)
        .allMatches(text)
        .map((match) => match.group(0)!.replaceFirst(RegExp(r'[.,;]+$'), ''));
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      final host = uri?.host.toLowerCase();
      if (host == null || host.isEmpty) continue;
      final base = host.contains('novelupdates')
          ? 'novelupdates'
          : host.contains('goodreads')
          ? 'goodreads'
          : host.contains('royalroad')
          ? 'royalroad'
          : host.contains('novel') || host.contains('novgo')
          ? 'fero_source'
          : 'source';
      var key = base;
      var suffix = 2;
      while (links.containsKey(key)) {
        key = '${base}_$suffix';
        suffix++;
      }
      links[key] = url;
    }
    return links;
  }

  static Iterable<String> _flattenText(Object? value) sync* {
    if (value is String) {
      yield value;
    } else if (value is Map) {
      for (final entry in value.entries) {
        yield* _flattenText(entry.value);
      }
    } else if (value is Iterable) {
      for (final entry in value) {
        yield* _flattenText(entry);
      }
    }
  }
}
