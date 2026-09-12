import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'media_areas.dart';
import '../scan/library_scanner.dart';

final class DocumentImportCandidate {
  const DocumentImportCandidate({
    required this.kind,
    required this.directory,
    required this.title,
    required this.files,
    this.coverFile,
    this.metadata = const {},
    this.embeddedCoverBytes,
    this.embeddedCoverMimeType,
  });

  final String kind;
  final String directory;
  final String title;
  final List<ScannedFile> files;
  final ScannedFile? coverFile;
  final Map<String, Object?> metadata;
  final Uint8List? embeddedCoverBytes;
  final String? embeddedCoverMimeType;

  /// The files that *are* the work, as opposed to the ones that sit beside
  /// it.
  ///
  /// A film folder holds the film, its poster, its fanart and whatever else
  /// somebody keeps there. All of it was being written down as content, so a
  /// film arrived at the player as five tracks — one of them the picture on
  /// its own cover — and the player showed a list of episodes for a work that
  /// has none. Where a kind has an unambiguous content type, that is what
  /// counts; everything else keeps every file, because a TTRPG product really
  /// is its maps and handouts.
  List<ScannedFile> get contentFiles {
    final wanted = _contentExtensions[kind];
    if (wanted == null) return files;
    final matching = files
        .where((file) => wanted.contains(file.extension))
        .toList(growable: false);
    // A folder with nothing of the expected type is still a work; showing
    // what is in it beats showing nothing.
    return matching.isEmpty ? files : matching;
  }

  // Die Schlüssel sind die Arten, unter denen ein Werk wirklich abgelegt
  // wird. „ebook" stand hier, angelegt wird aber „book" — dadurch behielt
  // jedes Buch sein Coverbild als Inhaltsdatei, und im Reiter „Dateien"
  // stand neben dem EPUB ein JPG.
  static const _contentExtensions = <String, Set<String>>{
    'movie': _videoExtensions,
    'tv': _videoExtensions,
    'anime': _videoExtensions,
    'book': _publicationExtensions,
    'ebook': _publicationExtensions,
    'webnovel': _publicationExtensions,
    'light_novel': _publicationExtensions,
    'novel': _publicationExtensions,
    'manga': _comicExtensions,
    'comic': _comicExtensions,
  };

  static const _videoExtensions = {
    'mp4',
    'm4v',
    'mkv',
    'webm',
    'mov',
    'avi',
    'wmv',
    'flv',
    'ts',
    'm2ts',
  };

  static const _publicationExtensions = {
    'epub',
    'pdf',
    'mobi',
    'azw',
    'azw3',
    'txt',
    'md',
    'html',
    'htm',
  };

  static const _comicExtensions = {'cbz', 'zip', 'cbr', 'rar', 'pdf', '7z'};

  DocumentImportCandidate copyWith({
    String? title,
    Map<String, Object?>? metadata,
    Uint8List? embeddedCoverBytes,
    String? embeddedCoverMimeType,
  }) => DocumentImportCandidate(
    kind: kind,
    directory: directory,
    title: title ?? this.title,
    files: files,
    coverFile: coverFile,
    metadata: metadata ?? this.metadata,
    embeddedCoverBytes: embeddedCoverBytes ?? this.embeddedCoverBytes,
    embeddedCoverMimeType: embeddedCoverMimeType ?? this.embeddedCoverMimeType,
  );
}

/// Groups non-audio media below explicitly configured media roots.
///
/// Each direct child directory is one portable work, including all supported
/// descendants. A file directly below a media root becomes its own work. This
/// keeps arbitrary folders outside those roots untouched and prevents an
/// audiobook's neighboring cover from becoming a separate image work.
final class DocumentImporter {
  DocumentImporter({
    required Map<String, Iterable<String>> mediaRoots,
    Map<String, Iterable<String>> sensitiveRoots = const {},
  }) : _areas = MediaAreaMap({
         for (final entry in mediaRoots.entries)
           if (_supportedKinds.contains(entry.key)) entry.key: entry.value,
       }, sensitiveRoots: sensitiveRoots);

  static const _supportedKinds = {
    'book',
    'webnovel',
    'manga',
    'image',
    'document',
    'ttrpg_product',
    'archive',
    'movie',
    'tv',
    'anime',
  };
  static const _extensions = {
    'pdf',
    'epub',
    'mobi',
    'azw',
    'azw3',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'svg',
    'txt',
    'md',
    'html',
    'htm',
    'zip',
    'cbz',
    '7z',
    'rar',
    'tar',
    'gz',
    'mp4',
    'm4v',
    'mkv',
    'webm',
    'mov',
    'avi',
    'wmv',
    'flv',
    'ts',
    'm2ts',
  };
  static const _coverNames = {
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp',
    'folder.jpg',
    'folder.jpeg',
    'folder.png',
    'folder.webp',
    'poster.jpg',
    'poster.jpeg',
    'poster.png',
    'poster.webp',
    'fanart.jpg',
    'fanart.png',
    'fanart.webp',
  };

  final MediaAreaMap _areas;

  List<DocumentImportCandidate> group(Iterable<ScannedFile> files) {
    final grouped = <String, _DocumentGroup>{};
    for (final file in files) {
      if (!_extensions.contains(file.extension)) continue;
      final area = _areas.locateFile(file.relativePath);
      if (area == null || area.remainder.isEmpty) continue;
      final kind = _workKind(area.kind);
      final remainder = area.remainder;
      final rootPath = area.rootPath;
      final standalone = remainder.length == 1;
      final sourcePath = standalone
          ? file.relativePath
          : p.posix.join(rootPath, remainder.first);
      final title = standalone
          ? p.basenameWithoutExtension(file.filename)
          : remainder.first;
      final key = '$kind\u0000$sourcePath';
      final group = grouped.putIfAbsent(
        key,
        () => _DocumentGroup(
          kind: kind,
          sourcePath: sourcePath,
          title: normalizeDocumentWorkTitle(kind, title),
        ),
      );
      group.contentSensitivity ??= area.contentSensitivity;
      group.files.add(file);
    }
    final candidates = [
      for (final group in grouped.values)
        DocumentImportCandidate(
          kind: group.kind,
          directory: group.sourcePath,
          title: group.title,
          files: group.files..sort(_compareFiles),
          coverFile: _cover(group.files, group.kind, title: group.title),
          metadata: {
            if (group.contentSensitivity != null)
              'content_sensitivity': group.contentSensitivity,
          },
        ),
    ];
    candidates.sort((left, right) {
      final kind = left.kind.compareTo(right.kind);
      return kind != 0
          ? kind
          : left.title.toLowerCase().compareTo(right.title.toLowerCase());
    });
    return candidates;
  }

  /// The picture that stands for a work.
  ///
  /// The fixed names catch a tidy library. Real folders are not tidy: an
  /// anime season carries „Chainsaw Man.jpg" beside the episodes, a scan
  /// carries „front.png", and a folder with exactly one picture in it means
  /// that picture. All of those left the work with a placeholder before.
  static ScannedFile? _cover(
    List<ScannedFile> files,
    String kind, {
    String? title,
  }) {
    final images = files
        .where((file) => file.mimeType?.startsWith('image/') ?? false)
        .toList(growable: false);
    if (images.isEmpty) return null;

    for (final file in images) {
      if (_coverNames.contains(file.filename.toLowerCase())) return file;
    }
    // A picture named after the work itself — how most video folders do it.
    final wanted = title?.toLowerCase().trim();
    if (wanted != null && wanted.isNotEmpty) {
      for (final file in images) {
        final base = file.filename.toLowerCase();
        final stem = base.contains('.')
            ? base.substring(0, base.lastIndexOf('.'))
            : base;
        if (stem == wanted) return file;
      }
    }
    // Then anything that calls itself a cover in some other language or
    // spelling, before falling back to the first picture there is.
    for (final file in images) {
      final base = file.filename.toLowerCase();
      if (_coverWords.any(base.contains)) return file;
    }
    // Whatever is left: the first picture in the folder, taken in the
    // scanner's own order. Better a wrong cover than none at all — a wrong
    // one is visibly wrong and can be replaced, a placeholder says nothing.
    return images.first;
  }

  static const _coverWords = {
    'cover',
    'poster',
    'folder',
    'front',
    'artwork',
    'albumart',
    'thumb',
    'banner',
    'keyart',
  };

  static int _compareFiles(ScannedFile left, ScannedFile right) =>
      _naturalCompare(left.relativePath, right.relativePath);

  static int _naturalCompare(String left, String right) {
    final pattern = RegExp(r'\d+|\D+');
    final leftParts = pattern
        .allMatches(left.toLowerCase())
        .map((match) => match.group(0)!)
        .toList(growable: false);
    final rightParts = pattern
        .allMatches(right.toLowerCase())
        .map((match) => match.group(0)!)
        .toList(growable: false);
    final length = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final leftPart = leftParts[index];
      final rightPart = rightParts[index];
      final leftNumber = BigInt.tryParse(leftPart);
      final rightNumber = BigInt.tryParse(rightPart);
      final comparison = leftNumber != null && rightNumber != null
          ? leftNumber.compareTo(rightNumber)
          : leftPart.compareTo(rightPart);
      if (comparison != 0) return comparison;
    }
    return leftParts.length.compareTo(rightParts.length);
  }

  static String _workKind(String configurationKind) =>
      switch (configurationKind) {
        'book' => 'ebook',
        _ => configurationKind,
      };
}

/// Removes chapter ranges that describe a webnovel file, not the work.
///
/// Downloaders commonly produce names such as `Nachtmeer - Kapitel 1-50`.
/// Keeping that suffix makes every later batch look like a different novel.
/// The rule is deliberately limited to webnovels and to a suffix at the end;
/// a legitimate title containing the word "Kapitel" is left alone.
String normalizeDocumentWorkTitle(String kind, String title) {
  if (kind != 'webnovel') return title;
  final cleaned = title
      .replaceFirst(
        RegExp(
          r'\s*(?:[-–—_:]|\[)\s*'
          r'(?:kapitel|chapter|chapters|ch\.?)\s*\d+'
          r'(?:\s*(?:[-–—]|bis|to)\s*\d+)?\s*\]?\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  return cleaned.isEmpty ? title : cleaned;
}

final class _DocumentGroup {
  _DocumentGroup({
    required this.kind,
    required this.sourcePath,
    required this.title,
  });

  final String kind;
  final String sourcePath;
  final String title;
  String? contentSensitivity;
  final List<ScannedFile> files = [];
}
