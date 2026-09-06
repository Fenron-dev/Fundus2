import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Reading pages out of a CBZ.
///
/// Ported from the previous client's `zip_archive_browser.dart` and
/// `comic_page_source.dart`, minus its dialog: the limits and the path
/// checking are the part that was hard-won and must not be rewritten from
/// memory. An archive is untrusted input — it may name `../../etc/passwd`,
/// carry a symlink, or unpack to a hundred gigabytes.
const _pageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// One page inside an archive.
final class ComicPage {
  const ComicPage({required this.id, required this.name, required this.size});

  /// The canonical path inside the archive; stable across openings.
  final String id;
  final String name;
  final int size;
}

/// Where a reader gets its pages — the counterpart of `MediaByteSource` for
/// paged works. The archive on disk makes the start; a chapter fetched from a
/// peer joins by implementing this, not by growing a second reader.
abstract interface class ComicPageSource {
  String get name;

  /// The pages, in reading order.
  Future<List<ComicPage>> pages();

  /// Writes the given pages into temporary files and returns page id → path.
  /// Only what is about to be shown gets unpacked; a volume is not expanded
  /// as a whole.
  Future<Map<String, String>> materialize(List<ComicPage> pages);

  Future<void> dispose();
}

final class ArchiveComicPageSource implements ComicPageSource {
  ArchiveComicPageSource(
    this.archivePath, {
    String? name,
    this.service = const ComicArchiveService(),
  }) : _name = name;

  final String archivePath;
  final String? _name;
  final ComicArchiveService service;
  final Map<String, ComicArchiveEntry> _entries = {};

  @override
  String get name => _name ?? p.basename(archivePath);

  @override
  Future<List<ComicPage>> pages() async {
    final entries = await service.pageEntries(archivePath);
    _entries
      ..clear()
      ..addEntries(entries.map((entry) => MapEntry(entry.path, entry)));
    return [
      for (final entry in entries)
        ComicPage(id: entry.path, name: entry.name, size: entry.size),
    ];
  }

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    if (pages.isEmpty) return const {};
    if (pages.any((page) => !_entries.containsKey(page.id))) {
      await this.pages();
    }
    final entries = <ComicArchiveEntry>[];
    for (final page in pages) {
      final entry = _entries[page.id];
      if (entry == null || entry.size != page.size || entry.name != page.name) {
        throw const ComicArchiveException(
          'Die Comicseite ist nicht mehr Teil dieser Quelle.',
        );
      }
      entries.add(entry);
    }
    return service.extract(archivePath, entries);
  }

  @override
  Future<void> dispose() async {}
}

/// A file inside an archive, with its name already checked.
final class ComicArchiveEntry {
  const ComicArchiveEntry({
    required this.path,
    required this.archiveName,
    required this.size,
  });

  /// The canonical path — checked for traversal, absolute roots and NUL.
  final String path;

  /// The name as the archive spells it, needed to find the entry again.
  final String archiveName;
  final int size;

  String get name => p.posix.basename(path);
}

/// Unpacking with limits, off the UI isolate.
final class ComicArchiveService {
  const ComicArchiveService({
    this.maxArchiveBytes = 1024 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxEntryBytes = 256 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  /// The image entries, in reading order. Decoding the directory of a large
  /// archive blocks; it belongs on its own isolate.
  Future<List<ComicArchiveEntry>> pageEntries(String archivePath) =>
      Isolate.run(() => _pageEntriesSync(archivePath));

  Future<Map<String, String>> extract(
    String archivePath,
    List<ComicArchiveEntry> targets,
  ) => Isolate.run(() => _extractSync(archivePath, targets));

  List<ComicArchiveEntry> _pageEntriesSync(String archivePath) {
    final file = File(archivePath);
    if (!file.existsSync()) {
      throw const ComicArchiveException('Die Datei ist nicht mehr vorhanden.');
    }
    if (file.lengthSync() > maxArchiveBytes) {
      throw const ComicArchiveException('Das Archiv ist zu groß.');
    }
    final archive = _decode(archivePath);
    try {
      if (archive.length > maxEntries) {
        throw const ComicArchiveException(
          'Das Archiv enthält zu viele Einträge.',
        );
      }
      var totalBytes = 0;
      final entries = <ComicArchiveEntry>[];
      for (final entry in archive) {
        if (entry.isSymbolicLink) {
          throw const ComicArchiveException(
            'Archive mit symbolischen Verknüpfungen werden nicht geöffnet.',
          );
        }
        if (!entry.isFile) continue;
        final canonical = _canonicalPath(entry.name);
        if (entry.size > maxEntryBytes) {
          throw ComicArchiveException(
            'Der Eintrag „${p.posix.basename(canonical)}“ ist zu groß.',
          );
        }
        totalBytes += entry.size;
        if (totalBytes > maxTotalBytes) {
          throw const ComicArchiveException(
            'Der entpackte Gesamtinhalt ist zu groß.',
          );
        }
        if (!_pageExtensions.contains(p.extension(canonical).toLowerCase())) {
          continue;
        }
        entries.add(
          ComicArchiveEntry(
            path: canonical,
            archiveName: entry.name,
            size: entry.size,
          ),
        );
      }
      // Page 2 sorts before page 10: scanners name files by number, and a
      // plain string sort turns a volume into nonsense.
      entries.sort((left, right) => naturalCompare(left.path, right.path));
      return entries;
    } finally {
      archive.clearSync();
    }
  }

  Map<String, String> _extractSync(
    String archivePath,
    List<ComicArchiveEntry> targets,
  ) {
    if (targets.isEmpty) return const {};
    final wanted = <String, ComicArchiveEntry>{};
    for (final target in targets) {
      if (_canonicalPath(target.archiveName) != target.path ||
          target.size > maxEntryBytes) {
        throw const ComicArchiveException(
          'Der Archiveintrag ist nicht mehr gültig.',
        );
      }
      wanted[target.archiveName] = target;
    }
    final archive = _decode(archivePath);
    Directory? directory;
    try {
      final root = scratchDirectory('fundus-comic-pages');
      _removeStale(root);
      directory = root.createTempSync('pages-');
      final result = <String, String>{};
      for (final entry in wanted.entries) {
        final target = entry.value;
        final file = archive.find(entry.key);
        if (file == null || !file.isFile || file.isSymbolicLink) {
          throw const ComicArchiveException(
            'Die Seite konnte im Archiv nicht gefunden werden.',
          );
        }
        if (file.size > maxEntryBytes) {
          throw const ComicArchiveException('Die Seite ist zu groß.');
        }
        final output = File(
          p.join(directory.path, '${result.length}-${target.name}'),
        );
        final stream = OutputFileStream(output.path);
        try {
          file.writeContent(stream);
        } finally {
          stream.closeSync();
        }
        if (output.lengthSync() > maxEntryBytes) {
          throw const ComicArchiveException(
            'Die Seite überschreitet beim Entpacken die Größenbegrenzung.',
          );
        }
        result[target.path] = output.path;
      }
      return result;
    } on ComicArchiveException {
      if (directory?.existsSync() ?? false) {
        directory!.deleteSync(recursive: true);
      }
      rethrow;
    } catch (_) {
      if (directory?.existsSync() ?? false) {
        directory!.deleteSync(recursive: true);
      }
      throw const ComicArchiveException(
        'Die Seite konnte nicht entpackt werden.',
      );
    } finally {
      archive.clearSync();
    }
  }

  Archive _decode(String archivePath) {
    try {
      return ZipDecoder().decodeStream(InputFileStream(archivePath));
    } catch (_) {
      throw const ComicArchiveException(
        'Das Archiv ist beschädigt oder verschlüsselt.',
      );
    }
  }

  /// Rejects everything that could write outside the temporary directory.
  static String _canonicalPath(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.contains('\u0000')) {
      throw const ComicArchiveException(
        'Das Archiv enthält einen unsicheren Pfad.',
      );
    }
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const ComicArchiveException(
        'Das Archiv enthält einen unsicheren Pfad.',
      );
    }
    return p.posix.joinAll(parts);
  }

  static void _removeStale(Directory root) {
    final oldest = DateTime.now().subtract(const Duration(days: 1));
    for (final entity in root.listSync(followLinks: false)) {
      try {
        if (entity.statSync().modified.isBefore(oldest)) {
          entity.deleteSync(recursive: true);
        }
      } catch (_) {
        // A directory still in use stays until a later pass.
      }
    }
  }
}

final class ComicArchiveException implements Exception {
  const ComicArchiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Compares two names the way a reader expects: „Seite 9“ before „Seite 10“.
int naturalCompare(String left, String right) {
  final leftParts = _naturalParts(left.toLowerCase());
  final rightParts = _naturalParts(right.toLowerCase());
  for (
    var index = 0;
    index < leftParts.length && index < rightParts.length;
    index++
  ) {
    final a = leftParts[index];
    final b = rightParts[index];
    if (a is int && b is int) {
      if (a != b) return a.compareTo(b);
      continue;
    }
    final comparison = a.toString().compareTo(b.toString());
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}

List<Object> _naturalParts(String value) {
  final parts = <Object>[];
  final buffer = StringBuffer();
  var digits = false;
  for (final rune in value.runes) {
    final isDigit = rune >= 0x30 && rune <= 0x39;
    if (buffer.isNotEmpty && isDigit != digits) {
      parts.add(digits ? int.parse(buffer.toString()) : buffer.toString());
      buffer.clear();
    }
    digits = isDigit;
    buffer.writeCharCode(rune);
  }
  if (buffer.isNotEmpty) {
    parts.add(digits ? int.parse(buffer.toString()) : buffer.toString());
  }
  return parts;
}

/// Ein Ordner für Seiten, die nur für diese Sitzung entstehen.
///
/// `Directory.systemTemp` zeigt in einer Sandbox auf einen Ort, den es noch
/// gar nicht gibt: „$Container/Data/tmp". „PDF öffnen" war deshalb schlicht
/// ein Fehler — angelegt wird der Ordner darum immer selbst, mitsamt seiner
/// Eltern, bevor jemand hineinschreibt.
Directory scratchDirectory(String name, {Directory? under}) =>
    Directory(p.join((under ?? Directory.systemTemp).path, name))
      ..createSync(recursive: true);
