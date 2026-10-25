import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Imports an Android CPU model into Fundus' private app storage. The system
/// picker grants access to one archive; the native Phonon engine then reads a
/// normal local directory without keeping broad storage permissions.
final class PhononModelStore {
  const PhononModelStore._();

  static const maxArchiveBytes = 1024 * 1024 * 1024;
  static const maxExpandedBytes = 768 * 1024 * 1024;
  static const maxFiles = 2048;
  static const _maxInstalledFiles = maxFiles + 1;
  static const integrityFileName = '.fundus-integrity.json';

  static Future<void> validateCpuModelDirectory(
    String directory,
  ) => Isolate.run(() {
    bool regular(String name) =>
        FileSystemEntity.typeSync(
          p.join(directory, name),
          followLinks: false,
        ) ==
        FileSystemEntityType.file;
    final config = File(p.join(directory, 'config.json'));
    final voices = Directory(p.join(directory, 'voices'));
    final hasVoice =
        regular('default-voice.safetensors') ||
        (voices.existsSync() &&
            voices
                .listSync(recursive: true, followLinks: false)
                .any(
                  (file) => file is File && file.path.endsWith('.safetensors'),
                ));
    if (!regular('config.json') ||
        !regular('tokenizer.json') ||
        !(regular('model.q8.gguf') || regular('model.safetensors')) ||
        !hasVoice) {
      throw const FormatException(
        'Wähle den Modellordner mit config.json, tokenizer.json, model.q8.gguf (oder model.safetensors) und default-voice.safetensors (oder voices/).',
      );
    }
    if (config.lengthSync() > 1024 * 1024) {
      throw const FormatException('Die Modellkonfiguration ist zu groß.');
    }
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map ||
        decoded['languages'] is! List ||
        (decoded['languages'] as List).isEmpty) {
      throw const FormatException(
        'Die Modellkonfiguration enthält keine Sprachen.',
      );
    }
  });

  static Future<String> importCpuModelArchive({
    required String archivePath,
    required String applicationSupportPath,
  }) => Isolate.run(
    () => _extractCpuModelArchive(archivePath, applicationSupportPath),
  );

  /// Verifies imported model files before the native engine reads them. For a
  /// model imported by an older Fundus release, it records a local baseline
  /// once. This detects later corruption, not a deliberately replaced model.
  static Future<void> verifyIntegrity(String modelDirectory) =>
      Isolate.run(() => _verifyModelIntegrity(modelDirectory));

  static bool isFundusImportedModel(String modelDirectory) =>
      p.basename(p.dirname(modelDirectory)) == 'phonon-models' &&
      p.basename(modelDirectory).startsWith('model-');
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
    if (paths.contains(PhononModelStore.integrityFileName)) {
      throw const FormatException(
        'Das Modellarchiv enthält einen reservierten Fundus-Dateinamen.',
      );
    }
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
      final hashes = <String, String>{};
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
        hashes[entry.path] = sha256.convert(bytes).toString();
      }
      final integrity = File(
        p.join(staging.path, PhononModelStore.integrityFileName),
      );
      integrity.writeAsStringSync(
        jsonEncode({'schema_version': 1, 'files': hashes}),
        flush: true,
      );
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

Future<void> _verifyModelIntegrity(String modelDirectory) async {
  final root = Directory(modelDirectory);
  if (!root.existsSync()) {
    throw const FormatException(
      'Der Phonon-Modellordner ist nicht erreichbar.',
    );
  }
  final manifest = File(p.join(root.path, PhononModelStore.integrityFileName));
  if (!manifest.existsSync()) {
    _writeIntegrityManifest(root);
    return;
  }

  late final Object? decoded;
  try {
    decoded = jsonDecode(manifest.readAsStringSync());
  } on Object {
    throw const FormatException(
      'Die Integritätsliste des Phonon-Modells ist beschädigt.',
    );
  }
  if (decoded is! Map || decoded['schema_version'] != 1) {
    throw const FormatException(
      'Die Integritätsliste des Phonon-Modells wird nicht unterstützt.',
    );
  }
  final rawFiles = decoded['files'];
  if (rawFiles is! Map || rawFiles.length > PhononModelStore.maxFiles) {
    throw const FormatException('Die Modell-Prüfliste ist ungültig.');
  }
  final expected = <String, String>{};
  for (final entry in rawFiles.entries) {
    if (entry.key is! String ||
        entry.value is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value as String) ||
        _safeArchivePath(entry.key as String) != entry.key) {
      throw const FormatException('Die Modell-Prüfliste ist ungültig.');
    }
    expected[entry.key as String] = entry.value as String;
  }

  final actual = _modelFiles(root)
      .where(
        (file) =>
            p.relative(file.path, from: root.path).replaceAll('\\', '/') !=
            PhononModelStore.integrityFileName,
      )
      .toList();
  final actualPaths = actual
      .map(
        (file) => p.relative(file.path, from: root.path).replaceAll('\\', '/'),
      )
      .toSet();
  if (actualPaths.length != expected.length ||
      !actualPaths.containsAll(expected.keys)) {
    throw const FormatException(
      'Modellintegrität fehlgeschlagen: Dateibestand geändert. Importiere das Modell erneut.',
    );
  }
  for (final file in actual) {
    final relative = p
        .relative(file.path, from: root.path)
        .replaceAll('\\', '/');
    if (relative == PhononModelStore.integrityFileName) continue;
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expected[relative]) {
      throw const FormatException(
        'Modellintegrität fehlgeschlagen: Eine Modell-Datei wurde verändert. Importiere das Modell erneut.',
      );
    }
  }
}

void _writeIntegrityManifest(Directory root) {
  final files =
      _modelFiles(root)
          .where(
            (file) =>
                p.relative(file.path, from: root.path).replaceAll('\\', '/') !=
                PhononModelStore.integrityFileName,
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty || files.length > PhononModelStore.maxFiles) {
    throw const FormatException('Der Modellordner enthält zu viele Dateien.');
  }
  final hashes = <String, String>{};
  for (final file in files) {
    final relative = p
        .relative(file.path, from: root.path)
        .replaceAll('\\', '/');
    if (_safeArchivePath(relative) == null) {
      throw const FormatException(
        'Der Phonon-Modellordner enthält einen ungültigen Pfad.',
      );
    }
    hashes[relative] = sha256.convert(file.readAsBytesSync()).toString();
  }
  File(p.join(root.path, PhononModelStore.integrityFileName)).writeAsStringSync(
    jsonEncode({'schema_version': 1, 'files': hashes}),
    flush: true,
  );
}

List<File> _modelFiles(Directory root) {
  final files = <File>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const FormatException(
        'Der Phonon-Modellordner enthält einen Link oder eine ungültige Datei.',
      );
    }
    if (type == FileSystemEntityType.file) files.add(File(entity.path));
  }
  if (files.length > PhononModelStore._maxInstalledFiles) {
    throw const FormatException('Der Modellordner enthält zu viele Dateien.');
  }
  return files;
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
