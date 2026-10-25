import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Imports an Android CPU model into Fundus' private app storage. The system
/// picker grants access to one archive; the native Phonon engine then reads a
/// normal local directory without keeping broad storage permissions.
final class PhononModelStore {
  const PhononModelStore._();

  static const maxArchiveBytes = 1024 * 1024 * 1024;
  static const maxExpandedBytes = 768 * 1024 * 1024;
  static const maxFiles = 2048;

  static Future<String> importCpuModelArchive({
    required String archivePath,
    required String applicationSupportPath,
  }) => Isolate.run(
    () => _extractCpuModelArchive(archivePath, applicationSupportPath),
  );
}

String _extractCpuModelArchive(String archivePath, String supportPath) {
  final archiveFile = File(archivePath);
  if (!archiveFile.existsSync()) {
    throw const FormatException('Das gewählte Modellarchiv ist nicht lesbar.');
  }
  final archiveLength = archiveFile.lengthSync();
  if (archiveLength <= 0 || archiveLength > PhononModelStore.maxArchiveBytes) {
    throw const FormatException('Das Modellarchiv ist leer oder zu groß.');
  }

  final input = InputFileStream(archivePath);
  late final Archive decoded;
  try {
    decoded = ZipDecoder().decodeStream(input);
    final files = decoded.files.where((file) => file.isFile).toList();
    if (files.isEmpty || files.length > PhononModelStore.maxFiles) {
      throw const FormatException('Das Modellarchiv enthält zu viele Dateien.');
    }

    final entries = <({ArchiveFile file, String path})>[];
    var expandedBytes = 0;
    for (final file in files) {
      final path = _safeArchivePath(file.name);
      if (path == null || file.isSymbolicLink) {
        throw const FormatException(
          'Das Modellarchiv enthält einen ungültigen Pfad.',
        );
      }
      expandedBytes += file.size;
      if (file.size < 0 || expandedBytes > PhononModelStore.maxExpandedBytes) {
        throw const FormatException('Das entpackte Modell ist zu groß.');
      }
      entries.add((file: file, path: path));
    }

    // A zip made from the model's containing folder has one redundant common
    // top-level directory. Remove only that single shared component.
    final topLevels = entries
        .map((entry) => p.posix.split(entry.path).first)
        .toSet();
    final stripRoot =
        topLevels.length == 1 &&
        entries.every((entry) => p.posix.split(entry.path).length > 1);
    final normalized = <({ArchiveFile file, String path})>[];
    final seen = <String>{};
    for (final entry in entries) {
      final parts = p.posix.split(entry.path);
      final path = stripRoot ? p.posix.joinAll(parts.skip(1)) : entry.path;
      if (path.isEmpty || !seen.add(path)) {
        throw const FormatException(
          'Das Modellarchiv enthält doppelte Dateien.',
        );
      }
      normalized.add((file: entry.file, path: path));
    }

    final paths = normalized.map((entry) => entry.path).toSet();
    final hasWeights =
        paths.contains('model.q8.gguf') || paths.contains('model.safetensors');
    final hasVoice =
        paths.contains('default-voice.safetensors') ||
        normalized.any(
          (entry) =>
              entry.path.startsWith('voices/') &&
              entry.path.endsWith('.safetensors'),
        );
    if (!paths.contains('config.json') ||
        !paths.contains('tokenizer.json') ||
        !hasWeights ||
        !hasVoice) {
      throw const FormatException(
        'Modell unvollständig: config.json, tokenizer.json, Gewichte und Stimme werden benötigt.',
      );
    }

    final root = Directory(p.join(supportPath, 'phonon-models'))
      ..createSync(recursive: true);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final staging = Directory(p.join(root.path, '.import-$suffix'))
      ..createSync();
    try {
      for (final entry in normalized) {
        final destination = File(
          p.joinAll([staging.path, ...p.posix.split(entry.path)]),
        );
        destination.parent.createSync(recursive: true);
        final bytes = entry.file.readBytes();
        if (bytes == null || bytes.length != entry.file.size) {
          throw const FormatException('Eine Modell-Datei ist beschädigt.');
        }
        destination.writeAsBytesSync(bytes, flush: true);
      }
      final installed = Directory(p.join(root.path, 'model-$suffix'));
      staging.renameSync(installed.path);
      return installed.path;
    } on Object {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      rethrow;
    }
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException(
      'Das Phonon-Modellarchiv konnte nicht entpackt werden.',
    );
  } finally {
    input.closeSync();
  }
}

String? _safeArchivePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return null;
  }
  final segments = normalized.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    return null;
  }
  return normalized;
}
