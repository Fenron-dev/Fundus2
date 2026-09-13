import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

final class LibraryConfiguration {
  LibraryConfiguration({
    Map<String, Iterable<String>>? mediaRoots,
    Map<String, Iterable<String>>? sensitiveRoots,
    Map<String, String>? mediaRootLabels,
  }) : mediaRoots = Map<String, List<String>>.unmodifiable({
         for (final entry in (mediaRoots ?? defaults).entries)
           entry.key: List<String>.unmodifiable(
             entry.value
                 .map((value) => _normalizeRoot(value))
                 .where((value) => value.isNotEmpty)
                 .toSet(),
           ),
       }),
       sensitiveRoots = Map<String, List<String>>.unmodifiable({
         for (final entry
             in (sensitiveRoots ?? const <String, Iterable<String>>{}).entries)
           entry.key: List<String>.unmodifiable(
             entry.value
                 .map((value) => _normalizeRoot(value))
                 .where((value) => value.isNotEmpty)
                 .toSet(),
           ),
       }),
       mediaRootLabels = Map<String, String>.unmodifiable({
         for (final entry
             in (mediaRootLabels ?? const <String, String>{}).entries)
           _normalizeRoot(entry.key): entry.value.trim(),
       });

  static const formatVersion = 1;

  /// Folder names a media area is recognised by.
  ///
  /// These are only defaults — the names people actually use win, and they are
  /// editable per library (see [LibraryConfiguration.write] and the
  /// "Medienordner" settings). Anything below a folder that matches no entry
  /// here stays unindexed, which is why the scan reports those folders instead
  /// of passing over them in silence.
  static const Map<String, List<String>> defaults = {
    'audiobook': ['Audiobooks', 'Hörbücher', 'Hoerbuecher', 'Hörspiele'],
    'movie': ['Movies', 'Filme'],
    'tv': ['TV Shows', 'Serien', 'Series'],
    'anime': ['Anime', 'Animes'],
    'book': ['Books', 'Bücher', 'Buecher', 'E-Books', 'EBooks', 'Ebooks'],
    'webnovel': [
      'Webnovels',
      'Web Novels',
      'Light Novels',
      'Light Novel',
      'Novels',
    ],
    'manga': ['Manga', 'Comics', 'Manhwa', 'Manhua'],
    'music': ['Music', 'Musik'],
    'podcast': ['Podcasts'],
    'image': ['Pictures', 'Bilder', 'Fotos', 'Photos'],
    'document': ['Documents', 'Dokumente'],
    'ttrpg_product': ['TTRPG'],
    'archive': ['Archives', 'Backups'],
  };

  final Map<String, List<String>> mediaRoots;
  final Map<String, List<String>> sensitiveRoots;
  final Map<String, String> mediaRootLabels;

  List<String> rootsFor(String kind) => mediaRoots[kind] ?? const [];

  List<String> sensitiveRootsFor(String kind) =>
      sensitiveRoots[kind] ?? const [];

  String displayNameFor(String root) {
    final normalized = _normalizeRoot(root);
    return mediaRootLabels[normalized] ?? normalized.split('/').last;
  }

  static Future<LibraryConfiguration> readOrDefault(File file) async {
    if (!await file.exists()) return LibraryConfiguration();
    final value = loadYaml(await file.readAsString());
    if (value is! Map) {
      throw const FormatException('Ungültige Fundus-Bibliothekskonfiguration.');
    }
    final roots = value['media_roots'];
    if (roots != null && roots is! Map) {
      throw const FormatException('media_roots muss eine Zuordnung sein.');
    }
    final parsed = <String, Iterable<String>>{};
    final rootEntries = roots is Map ? roots.entries : const <MapEntry>[];
    for (final entry in rootEntries) {
      if (entry.key is! String || entry.value is! List) {
        throw const FormatException('Ungültiger Eintrag unter media_roots.');
      }
      parsed[entry.key as String] = (entry.value as List).map((value) {
        if (value is! String) {
          throw const FormatException('Medienbereichspfade müssen Text sein.');
        }
        return value;
      });
    }
    final sensitive = <String, Iterable<String>>{};
    final configuredSensitive = value['sensitive_roots'];
    if (configuredSensitive is Map) {
      for (final entry in configuredSensitive.entries) {
        if (entry.key is String && entry.value is List) {
          sensitive[entry.key as String] = (entry.value as List)
              .whereType<String>();
        }
      }
    }
    final labels = <String, String>{};
    final configuredLabels = value['media_root_labels'];
    if (configuredLabels is Map) {
      for (final entry in configuredLabels.entries) {
        if (entry.key is String && entry.value is String) {
          final key = _normalizeRoot(entry.key as String);
          final label = (entry.value as String).trim();
          if (key.isNotEmpty && label.isNotEmpty) labels[key] = label;
        }
      }
    }
    return LibraryConfiguration(
      mediaRoots: {...defaults, ...parsed},
      sensitiveRoots: sensitive,
      mediaRootLabels: labels,
    );
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'format_version': formatVersion, 'media_roots': mediaRoots, if (mediaRootLabels.isNotEmpty) 'media_root_labels': mediaRootLabels, if (sensitiveRoots.isNotEmpty) 'sensitive_roots': sensitiveRoots})}\n',
      flush: true,
    );
  }

  static String _normalizeRoot(String value) => value
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');
}
