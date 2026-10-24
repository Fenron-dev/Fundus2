import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'epub_package.dart';
import 'reflow_document.dart';

/// Structural metadata only. Text and media bytes are never sent as part of
/// a chapter manifest. IDs are the same IDs the existing EPUB reader uses.
final class PublicationUnit {
  const PublicationUnit({
    required this.id,
    required this.title,
    required this.revision,
  });

  final String id;
  final String title;
  final String revision;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'revision': revision,
  };

  static PublicationUnit fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['title'] is! String ||
        value['revision'] is! String ||
        (value['id'] as String).isEmpty ||
        (value['id'] as String).length > 4096 ||
        (value['title'] as String).length > 4096 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['revision'] as String)) {
      throw const FormatException('Ungültige Kapitelmetadaten.');
    }
    return PublicationUnit(
      id: value['id'] as String,
      title: value['title'] as String,
      revision: value['revision'] as String,
    );
  }
}

final class PublicationManifest {
  const PublicationManifest({
    required this.fileRevision,
    required this.units,
    this.supported = true,
  });

  static const maxBytes = 4 * 1024 * 1024;
  final String fileRevision;
  final List<PublicationUnit> units;
  final bool supported;

  Map<String, Object?> toJson() => {
    'format_version': 1,
    'file_revision': fileRevision,
    'units': units.map((unit) => unit.toJson()).toList(),
    'supported': supported,
  };

  static PublicationManifest fromJson(Object? value) {
    if (value is! Map ||
        value['format_version'] != 1 ||
        value['file_revision'] is! String ||
        (value['file_revision'] as String).length > 512 ||
        (value.containsKey('supported') && value['supported'] is! bool) ||
        value['units'] is! List ||
        (value['units'] as List).length > 10000 ||
        utf8.encode(jsonEncode(value)).length > maxBytes) {
      throw const FormatException('Nicht unterstützter Kapitelbestand.');
    }
    final units = (value['units'] as List)
        .map(PublicationUnit.fromJson)
        .toList();
    if (units.map((unit) => unit.id).toSet().length != units.length) {
      throw const FormatException('Kapitelkennungen sind nicht eindeutig.');
    }
    if (value['supported'] == false && units.isNotEmpty) {
      throw const FormatException(
        'Nicht unterstützte Publikation enthält Kapitel.',
      );
    }
    return PublicationManifest(
      fileRevision: value['file_revision'] as String,
      units: List.unmodifiable(units),
      supported: value['supported'] != false,
    );
  }

  /// Archive decoding and hashing run off the UI/server isolate. The caller
  /// owns concurrency and verifies that the indexed file did not change.
  static Future<PublicationManifest> readFile(String path, String revision) =>
      Isolate.run(() async {
        final publication = await const EpubPackageAdapter().openFile(path);
        return PublicationManifest.fromJson({
          'format_version': 1,
          'file_revision': revision,
          'units': [
            for (final chapter in publication.chapters)
              if (ReflowDocument.parse(
                chapter.html,
                format: ReflowSourceFormat.html,
              ).paragraphs.isNotEmpty)
                {
                  'id': chapter.id,
                  'title': chapter.title,
                  'revision': sha256
                      .convert(utf8.encode(chapter.html))
                      .toString(),
                },
          ],
        });
      });
}
