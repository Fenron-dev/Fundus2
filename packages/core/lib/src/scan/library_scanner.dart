import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audio_technical_metadata.dart';
import '../video/video_metadata.dart';

enum ScanEventKind { started, file, skipped, error, completed, cancelled }

final class ScannedFile {
  const ScannedFile({
    required this.absolutePath,
    required this.relativePath,
    required this.filename,
    required this.extension,
    required this.size,
    required this.modifiedAt,
    required this.mimeType,
    this.audioMetadata,
    this.videoEpisode,
    this.unchanged = false,
  });

  final String absolutePath;
  final String relativePath;
  final String filename;
  final String extension;
  final int size;
  final DateTime modifiedAt;
  final String? mimeType;
  final AudioTechnicalMetadata? audioMetadata;
  final VideoEpisodeIdentity? videoEpisode;

  /// The index already holds this file with this size and time.
  ///
  /// Nothing was read from it beyond what `stat` returned, so
  /// [audioMetadata] and [videoEpisode] are absent even where the file has
  /// them — the stored row is where they live.
  final bool unchanged;
}

/// Answers whether the index already knows a file exactly as it is on disk.
typedef ScannedFileStamp =
    bool Function(String relativePath, int size, DateTime modifiedAt);

final class ScanEvent {
  const ScanEvent({
    required this.kind,
    required this.visitedFiles,
    this.file,
    this.path,
    this.error,
  });

  final ScanEventKind kind;
  final int visitedFiles;
  final ScannedFile? file;
  final String? path;
  final Object? error;
}

final class ScanCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Walks a vault and reports what is in it.
///
/// `base` rather than `final`: the one failure mode worth modelling in a test
/// is a folder that refuses to answer, and that cannot be arranged on a real
/// file system without depending on who is running the test.
base class LibraryScanner {
  LibraryScanner({
    this.ignoredDirectoryNames = const {
      '.library',
      '.chapters',
      '_fundus',
      '.staging',
      '.git',
      '@eaDir',
      '#recycle',
      r'$RECYCLE.BIN',
      '.AppleDB',
      '.AppleDesktop',
      '.AppleDouble',
      '.TemporaryItems',
      '.DocumentRevisions-V100',
      '.Spotlight-V100',
      '.Trashes',
      '.fseventsd',
    },
    this.ignoredFileNames = const {'.DS_Store', 'Thumbs.db'},
  });

  final Set<String> ignoredDirectoryNames;
  final Set<String> ignoredFileNames;

  /// Walks [root] and reports every file it finds.
  ///
  /// [isUnchanged] turns a scan into a check: a file the index already holds
  /// with the same size and time is reported with [ScannedFile.unchanged] set
  /// and is never opened. Reading headers out of every audio file is what
  /// makes a full pass take minutes; skipping it for the files nobody touched
  /// is what makes „ich habe eine Serie hinzugefügt" cost seconds.
  ///
  /// [subtree] limits the walk to one folder below [root]. Deletions can then
  /// only be judged inside it, which is why the library scopes the missing
  /// mark to the same path.
  Stream<ScanEvent> scan(
    Directory root, {
    ScanCancellationToken? cancellationToken,
    ScannedFileStamp? isUnchanged,
    String? subtree,
  }) async* {
    final rootPath = p.normalize(root.absolute.path);
    var visited = 0;
    yield ScanEvent(
      kind: ScanEventKind.started,
      visitedFiles: visited,
      path: rootPath,
    );

    if (!await root.exists()) {
      yield ScanEvent(
        kind: ScanEventKind.error,
        visitedFiles: visited,
        path: rootPath,
        error: FileSystemException('Bibliothek existiert nicht.', rootPath),
      );
      return;
    }

    final start = subtree == null || subtree.trim().isEmpty
        ? root.absolute
        : Directory(
            p.normalize(p.join(rootPath, p.joinAll(p.posix.split(subtree)))),
          );
    if (start.path != rootPath && !await start.exists()) {
      yield ScanEvent(kind: ScanEventKind.completed, visitedFiles: visited);
      return;
    }
    final pending = <Directory>[start];
    final visitedDirectories = <String>{};
    final visitedFiles = <String>{};
    while (pending.isNotEmpty) {
      if (cancellationToken?.isCancelled ?? false) {
        yield ScanEvent(kind: ScanEventKind.cancelled, visitedFiles: visited);
        return;
      }

      final directory = pending.removeLast();
      final directoryPath = p.normalize(directory.absolute.path);
      if (!visitedDirectories.add(directoryPath)) continue;
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (cancellationToken?.isCancelled ?? false) {
            yield ScanEvent(
              kind: ScanEventKind.cancelled,
              visitedFiles: visited,
            );
            return;
          }
          final name = p.basename(entity.path);
          if (entity is Directory) {
            if (!_isIgnoredDirectory(name)) pending.add(entity);
            continue;
          }
          if (entity is! File ||
              ignoredFileNames.contains(name) ||
              name.startsWith('._')) {
            continue;
          }

          try {
            final stat = await entity.stat();
            final extension = p
                .extension(name)
                .toLowerCase()
                .replaceFirst('.', '');
            final relative = p.relative(entity.absolute.path, from: rootPath);
            if (relative == '..' || relative.startsWith('../')) {
              yield ScanEvent(
                kind: ScanEventKind.skipped,
                visitedFiles: visited,
                path: entity.path,
              );
              continue;
            }
            final portableRelative = p.posix.joinAll(p.split(relative));
            // SMB providers can return an entry more than once while
            // generated files are changing during a scan.
            if (!visitedFiles.add(portableRelative)) continue;
            visited++;
            final known =
                isUnchanged?.call(portableRelative, stat.size, stat.modified) ??
                false;
            yield ScanEvent(
              kind: ScanEventKind.file,
              visitedFiles: visited,
              file: ScannedFile(
                absolutePath: entity.absolute.path,
                relativePath: portableRelative,
                filename: name,
                extension: extension,
                size: stat.size,
                modifiedAt: stat.modified,
                mimeType: _mimeTypes[extension],
                unchanged: known,
                videoEpisode: known || !_videoExtensions.contains(extension)
                    ? null
                    : parseVideoEpisode(name),
                audioMetadata: known
                    ? null
                    : await AudioTechnicalMetadataProbe.inspect(
                        entity,
                        extension,
                        stat.size,
                      ),
              ),
            );
          } catch (error) {
            yield ScanEvent(
              kind: ScanEventKind.error,
              visitedFiles: visited,
              path: entity.path,
              error: error,
            );
          }
        }
      } catch (error) {
        yield ScanEvent(
          kind: ScanEventKind.error,
          visitedFiles: visited,
          path: directory.path,
          error: error,
        );
      }
    }

    yield ScanEvent(kind: ScanEventKind.completed, visitedFiles: visited);
  }

  bool _isIgnoredDirectory(String name) {
    final normalized = name.toLowerCase();
    if (normalized.startsWith('.trash-')) return true;
    return ignoredDirectoryNames.any(
      (ignored) => ignored.toLowerCase() == normalized,
    );
  }
}

const _mimeTypes = <String, String>{
  'm4b': 'audio/mp4',
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'avi': 'video/x-msvideo',
  'wmv': 'video/x-ms-wmv',
  'flv': 'video/x-flv',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  'pdf': 'application/pdf',
  'epub': 'application/epub+zip',
  'zip': 'application/zip',
  'cbz': 'application/vnd.comicbook+zip',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

const _videoExtensions = {
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
