import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

/// Hashes model data off the UI/server isolate and reuses the snapshot while
/// file sizes and modification times remain the same.
final class SharedSpeechModel {
  String? _key;
  Future<SpeechModelManifest>? _pending;

  Future<SpeechModelManifest> manifest(String directory) async {
    final key = await Isolate.run(() => _snapshotKey(directory));
    if (_key == key && _pending != null) return _pending!;
    _key = key;
    final operation = Isolate.run(() => _manifest(directory));
    _pending = operation;
    try {
      return await operation;
    } on Object {
      if (_key == key) {
        _key = null;
        _pending = null;
      }
      rethrow;
    }
  }

  File file(String directory, SpeechModelFile entry) {
    // Resolve each parent too: rejecting just the final link still permits
    // a voices/ directory pointing outside the configured model.
    final root = Directory(directory).resolveSymbolicLinksSync();
    final file = File(p.joinAll([root, ...entry.path.split('/')]));
    if (!p.equals(file.resolveSymbolicLinksSync(), file.path) ||
        file.lengthSync() != entry.bytes) {
      throw const FormatException('Die Sprachmodell-Datei wurde verändert.');
    }
    return file;
  }
}

String _snapshotKey(String directory) {
  final files = _files(directory);
  return '$directory:${files.map((file) {
    final stat = file.statSync();
    return '${file.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }).join('|')}';
}

List<File> _files(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) {
    throw const FormatException('Der CPU-Modellordner ist nicht erreichbar.');
  }
  final files = <File>[];
  var visited = 0;
  // List only the selected folder and voices, never another part of the vault.
  void collect(Directory folder) {
    for (final entry in folder.listSync(followLinks: false)) {
      if (++visited > SpeechModelManifest.maxFiles * 2 ||
          files.length >= SpeechModelManifest.maxFiles) {
        throw const FormatException('Zu viele Modell-Dateien.');
      }
      final path = p
          .relative(entry.path, from: directory)
          .replaceAll('\\', '/');
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      if (path.split('/').length > 8 ||
          (type == FileSystemEntityType.link &&
              (path == 'voices' || SpeechModelFile.isAllowedPath(path)))) {
        throw const FormatException('Ungültiger Sprachmodell-Pfad.');
      }
      if (type == FileSystemEntityType.directory &&
          (path == 'voices' || path.startsWith('voices/'))) {
        collect(Directory(entry.path));
      } else if (SpeechModelFile.isAllowedPath(path)) {
        if (type != FileSystemEntityType.file) {
          throw const FormatException(
            'Modell-Dateien dürfen keine Verknüpfungen sein.',
          );
        }
        files.add(File(entry.path));
      }
    }
  }

  collect(root);
  // CPU prefers Q8 and never needs to transfer both full-size weight formats.
  if (files.any((file) => p.basename(file.path) == 'model.q8.gguf')) {
    files.removeWhere((file) => p.basename(file.path) == 'model.safetensors');
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Future<SpeechModelManifest> _manifest(String directory) async {
  final files = _files(directory);
  var bytes = 0;
  final entries = <SpeechModelFile>[];
  for (final file in files) {
    final before = file.statSync();
    bytes += before.size;
    if (bytes > SpeechModelManifest.maxBytes) {
      throw const FormatException('Das CPU-Modell ist zu groß.');
    }
    final digest = await sha256.bind(file.openRead()).first;
    final after = file.statSync();
    if (before.size != after.size || before.modified != after.modified) {
      throw const FormatException(
        'Das Sprachmodell wurde während der Prüfung verändert.',
      );
    }
    entries.add(
      SpeechModelFile(
        path: p.relative(file.path, from: directory).replaceAll('\\', '/'),
        bytes: before.size,
        sha256: digest.toString(),
      ),
    );
  }
  final configFile = File(p.join(directory, 'config.json'));
  if (!configFile.existsSync() || configFile.lengthSync() > 1024 * 1024) {
    throw const FormatException(
      'Die CPU-Modellkonfiguration fehlt oder ist zu groß.',
    );
  }
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final languages = (config['languages'] as List? ?? []).cast<String>();
  return SpeechModelManifest(
    id: sha256
        .convert(
          utf8.encode(
            jsonEncode(entries.map((file) => file.toJson()).toList()),
          ),
        )
        .toString(),
    languages: languages,
    files: entries,
  );
}
