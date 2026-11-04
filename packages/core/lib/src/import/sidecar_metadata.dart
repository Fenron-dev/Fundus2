import 'dart:io';

import 'package:xml/xml.dart';

import 'mediavault_metadata.dart';

/// Metadata other media managers leave beside a work.
///
/// Kodi, Jellyfin and Emby write `.nfo` files, Calibre writes `metadata.opf`.
/// Both are read, never written, and land in the same record as a Fero
/// sidecar, so they go through the same import and the same conflict review.
///
/// The XML parser expands no external entities and no document type
/// definitions; a file is read only up to [sidecarMetadataMaximumBytes].
const sidecarMetadataMaximumBytes = 2 * 1024 * 1024;

/// Reads a Kodi/Jellyfin/Emby `.nfo` file.
///
/// An `.nfo` that is not XML — a release note, often with nothing but a link
/// in it — still gives away the IMDb or TMDB id it mentions.
final class NfoMetadataReader {
  const NfoMetadataReader();

  Future<MediaVaultMetadata?> read(File file) async {
    final text = await _readBounded(file);
    if (text == null) return null;
    final trimmed = text.replaceFirst('﻿', '').trimLeft();
    if (!trimmed.startsWith('<')) return _fromPlainText(trimmed);
    final XmlDocument document;
    try {
      document = XmlDocument.parse(trimmed);
    } on XmlException {
      return _fromPlainText(trimmed);
    }
    final root = document.rootElement;
    if (!const {
      'movie',
      'tvshow',
      'episodedetails',
      'musicvideo',
    }.contains(root.name.local.toLowerCase())) {
      return null;
    }
    String? text1(String name) => _cleanText(_child(root, name)?.innerText);
    Iterable<String> all(String name) => root.childElements
        .where((element) => element.name.local.toLowerCase() == name)
        .map((element) => _cleanText(element.innerText))
        .whereType<String>();

    final title = text1('title');
    final original = text1('originaltitle');
    final ids = <String, String>{};
    for (final element in root.childElements.where(
      (element) => element.name.local.toLowerCase() == 'uniqueid',
    )) {
      final type = element.getAttribute('type')?.trim().toLowerCase();
      final value = _cleanText(element.innerText);
      if (type == null || value == null) continue;
      final key = _idKey(type);
      if (key != null) ids.putIfAbsent(key, () => value);
    }
    for (final (name, key) in const [
      ('imdbid', 'imdb'),
      ('imdb_id', 'imdb'),
      ('tmdbid', 'tmdb'),
      ('tvdbid', 'tvdb'),
    ]) {
      final value = text1(name);
      if (value != null) ids.putIfAbsent(key, () => value);
    }
    final legacyId = text1('id');
    if (legacyId != null && RegExp(r'^tt\d{6,9}$').hasMatch(legacyId)) {
      ids.putIfAbsent('imdb', () => legacyId);
    }
    final premiered =
        text1('premiered') ?? text1('aired') ?? text1('releasedate');
    final year =
        int.tryParse(text1('year') ?? '') ??
        (premiered == null
            ? null
            : int.tryParse(
                RegExp(r'^(\d{4})').firstMatch(premiered)?.group(1) ?? '',
              ));
    final set = _child(root, 'set');
    final collection = set == null
        ? null
        : _cleanText(_child(set, 'name')?.innerText) ??
              (set.childElements.isEmpty ? _cleanText(set.innerText) : null);
    return MediaVaultMetadata(
      title: title,
      authors: all('director').toSet().toList(growable: false),
      alternateTitles: [if (original != null && original != title) original],
      description: _cleanText(
        _child(root, 'plot')?.innerText ?? _child(root, 'outline')?.innerText,
        maximumLength: 50000,
      ),
      series: collection,
      sequence: root.name.local.toLowerCase() == 'episodedetails'
          ? double.tryParse(text1('episode') ?? '')
          : null,
      publisher: all('studio').firstOrNull,
      publishedYear: year != null && year > 1800 && year < 3000 ? year : null,
      genres: {
        for (final genre in all('genre'))
          for (final part in genre.split(RegExp(r'\s*/\s*')))
            if (part.trim().isNotEmpty) part.trim(),
      }.toList(growable: false),
      tags: all('tag').toSet().toList(growable: false),
      externalRating: _rating(root),
      sourceLinks: ids,
    );
  }

  static double? _rating(XmlElement root) {
    final ratings = _child(root, 'ratings');
    if (ratings != null) {
      final entries = ratings.childElements.toList();
      final chosen =
          entries
              .where((entry) => entry.getAttribute('default') == 'true')
              .firstOrNull ??
          entries.firstOrNull;
      final value = chosen == null
          ? null
          : double.tryParse(_child(chosen, 'value')?.innerText.trim() ?? '');
      if (value != null) return value;
    }
    return double.tryParse(_child(root, 'rating')?.innerText.trim() ?? '');
  }

  static MediaVaultMetadata? _fromPlainText(String text) {
    final ids = <String, String>{};
    final imdb = RegExp(r'imdb\.com/title/(tt\d{6,9})').firstMatch(text);
    if (imdb != null) ids['imdb'] = imdb.group(1)!;
    final tmdb = RegExp(r'themoviedb\.org/(movie|tv)/(\d+)').firstMatch(text);
    if (tmdb != null) ids['tmdb'] = tmdb.group(2)!;
    final tvdb = RegExp(r'thetvdb\.com/.*?[?&/]id=?(\d+)').firstMatch(text);
    if (tvdb != null) ids['tvdb'] = tvdb.group(1)!;
    return ids.isEmpty ? null : MediaVaultMetadata(sourceLinks: ids);
  }

  static String? _idKey(String type) => switch (type) {
    'imdb' => 'imdb',
    'tmdb' || 'themoviedb' => 'tmdb',
    'tvdb' || 'thetvdb' => 'tvdb',
    'anidb' => 'anidb',
    'anilist' => 'anilist',
    'mal' || 'myanimelist' => 'myanimelist',
    'trakt' => 'trakt',
    _ => null,
  };
}

/// Reads Calibre's `metadata.opf`, OPF 2 and the OPF 3 series notation.
final class CalibreOpfReader {
  const CalibreOpfReader();

  Future<MediaVaultMetadata?> read(File file) async {
    final text = await _readBounded(file);
    if (text == null) return null;
    final XmlDocument document;
    try {
      document = XmlDocument.parse(text.replaceFirst('﻿', ''));
    } on XmlException {
      return null;
    }
    final package = document.rootElement;
    if (package.name.local != 'package') return null;
    final metadata = package.childElements
        .where((element) => element.name.local == 'metadata')
        .firstOrNull;
    if (metadata == null) return null;
    Iterable<XmlElement> dc(String name) =>
        metadata.childElements.where((element) => element.name.local == name);
    String? first(String name) => dc(
      name,
    ).map((element) => _cleanText(element.innerText)).nonNulls.firstOrNull;
    String? metaNamed(String name) => metadata.childElements
        .where(
          (element) =>
              element.name.local == 'meta' &&
              element.getAttribute('name') == name,
        )
        .map((element) => _cleanText(element.getAttribute('content')))
        .nonNulls
        .firstOrNull;
    String? role(XmlElement element) => element.attributes
        .where((attribute) => attribute.name.local == 'role')
        .map((attribute) => attribute.value)
        .firstOrNull;

    final authors = [
      for (final creator in dc('creator'))
        if (role(creator) == null || role(creator) == 'aut')
          ?_cleanText(creator.innerText),
    ];
    final ids = <String, String>{};
    for (final identifier in dc('identifier')) {
      final scheme = identifier.attributes
          .where((attribute) => attribute.name.local == 'scheme')
          .map((attribute) => attribute.value.toLowerCase())
          .firstOrNull;
      final value = _cleanText(identifier.innerText);
      if (value == null) continue;
      var key = switch (scheme) {
        'isbn' => 'isbn',
        'goodreads' => 'goodreads',
        'amazon' || 'mobi-asin' => 'amazon',
        'google' => 'google_books',
        'openlibrary' => 'openlibrary',
        _ => null,
      };
      var id = value;
      // OPF 3 writes `urn:isbn:978…` without a scheme attribute.
      final urn = RegExp(r'^urn:([a-z]+):(.+)$').firstMatch(value);
      if (key == null && urn != null && urn.group(1) == 'isbn') {
        key = 'isbn';
        id = urn.group(2)!;
      }
      if (key != null) ids.putIfAbsent(key, () => id);
    }

    // OPF 3: <meta property="belongs-to-collection" id="c">Serie</meta>
    // with <meta refines="#c" property="group-position">2</meta>.
    String? series = metaNamed('calibre:series');
    var sequence = double.tryParse(metaNamed('calibre:series_index') ?? '');
    if (series == null) {
      final collection = metadata.childElements
          .where(
            (element) =>
                element.name.local == 'meta' &&
                element.getAttribute('property') == 'belongs-to-collection',
          )
          .firstOrNull;
      series = _cleanText(collection?.innerText);
      final id = collection?.getAttribute('id');
      if (id != null) {
        final position = metadata.childElements
            .where(
              (element) =>
                  element.name.local == 'meta' &&
                  element.getAttribute('refines') == '#$id' &&
                  element.getAttribute('property') == 'group-position',
            )
            .firstOrNull;
        sequence ??= double.tryParse(position?.innerText.trim() ?? '');
      }
    }
    final date = first('date');
    final year = int.tryParse(
      RegExp(r'^(\d{4})').firstMatch(date ?? '')?.group(1) ?? '',
    );
    // Calibre rates on a ten-point scale: two per star.
    final rating = double.tryParse(metaNamed('calibre:rating') ?? '');
    final cover = package.childElements
        .where((element) => element.name.local == 'guide')
        .expand((guide) => guide.childElements)
        .where((reference) => reference.getAttribute('type') == 'cover')
        .map((reference) => reference.getAttribute('href'))
        .nonNulls
        .firstOrNull;
    return MediaVaultMetadata(
      title: first('title'),
      authors: authors.toSet().toList(growable: false),
      description: _plainText(first('description')),
      series: series,
      sequence: sequence,
      language: first('language'),
      publisher: first('publisher'),
      // Calibre writes 0101-01-01 for "no date".
      publishedYear: year != null && year > 1000 && year < 3000 ? year : null,
      tags: {
        for (final subject in dc('subject')) ?_cleanText(subject.innerText),
      }.toList(growable: false),
      externalRating: rating == null || rating <= 0 ? null : rating / 2,
      coverPath: cover == null ? null : Uri.decodeFull(cover),
      sourceLinks: ids,
    );
  }

  /// Calibre keeps the description as HTML; Fundus shows text.
  static String? _plainText(String? html) {
    if (html == null) return null;
    final text = html
        .replaceAll(
          RegExp(r'<\s*(br|/p|/div|/li)\s*/?>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return _cleanText(text, maximumLength: 50000);
  }
}

Future<String?> _readBounded(File file) async {
  try {
    if (!await file.exists() ||
        await file.length() > sidecarMetadataMaximumBytes) {
      return null;
    }
    return await file.readAsString();
  } on FileSystemException {
    return null;
  } on FormatException {
    // Not UTF-8. An old Latin-1 release note carries nothing worth guessing.
    return null;
  }
}

XmlElement? _child(XmlElement parent, String name) => parent.childElements
    .where((element) => element.name.local.toLowerCase() == name)
    .firstOrNull;

String? _cleanText(String? value, {int maximumLength = 1000}) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > maximumLength
      ? trimmed.substring(0, maximumLength)
      : trimmed;
}
