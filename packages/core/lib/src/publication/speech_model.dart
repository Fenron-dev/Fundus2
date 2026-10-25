/// The data a paired server may supply for local CPU speech synthesis.
/// Executables, arbitrary paths and unrelated files never enter this protocol.
final class SpeechModelManifest {
  SpeechModelManifest({
    required this.id,
    required this.languages,
    required this.files,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        files.isEmpty ||
        files.length > maxFiles ||
        files.map((file) => file.path).toSet().length != files.length ||
        totalBytes > maxBytes ||
        languages.isEmpty ||
        languages.any(
          (code) => !const {'en', 'de', 'fr', 'es', 'pt'}.contains(code),
        )) {
      throw const FormatException('Das Sprachmodell-Angebot ist ungültig.');
    }
    final paths = files.map((file) => file.path).toSet();
    if (!paths.contains('config.json') ||
        !paths.contains('tokenizer.json') ||
        !(paths.contains('model.q8.gguf') ||
            paths.contains('model.safetensors')) ||
        !(paths.contains('default-voice.safetensors') ||
            paths.any((path) => path.startsWith('voices/')))) {
      throw const FormatException(
        'Das CPU-Sprachmodell ist unvollständig: Konfiguration, Tokenizer, Gewichte und Stimme werden benötigt.',
      );
    }
  }

  static const maxBytes = 768 * 1024 * 1024;
  static const maxFiles = 2048;
  final String id;
  final List<String> languages;
  final List<SpeechModelFile> files;
  int get totalBytes => files.fold(0, (sum, file) => sum + file.bytes);

  factory SpeechModelManifest.fromJson(Map<String, Object?> json) {
    if (json['schema_version'] != 1 ||
        json['files'] is! List ||
        json['languages'] is! List) {
      throw const FormatException(
        'Das Sprachmodell-Angebot wird nicht unterstützt.',
      );
    }
    final entries = json['files'] as List;
    if (entries.length > maxFiles) {
      throw const FormatException('Zu viele Sprachmodell-Dateien.');
    }
    return SpeechModelManifest(
      id: json['id'] as String? ?? '',
      languages: (json['languages'] as List).cast<String>(),
      files: entries
          .map(
            (entry) => SpeechModelFile.fromJson(
              Map<String, Object?>.from(entry as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'languages': languages,
    'files': files.map((file) => file.toJson()).toList(growable: false),
  };
}

final class SpeechModelFile {
  SpeechModelFile({
    required this.path,
    required this.bytes,
    required this.sha256,
  }) {
    if (!isAllowedPath(path) ||
        bytes <= 0 ||
        bytes > SpeechModelManifest.maxBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Eine Sprachmodell-Datei ist ungültig.');
    }
  }

  final String path;
  final int bytes;
  final String sha256;
  factory SpeechModelFile.fromJson(Map<String, Object?> json) =>
      SpeechModelFile(
        path: json['path'] as String? ?? '',
        bytes: json['bytes'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
      );
  Map<String, Object?> toJson() => {
    'path': path,
    'bytes': bytes,
    'sha256': sha256,
  };

  static bool isAllowedPath(String path) {
    if (path.contains('\\') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(path)) {
      return false;
    }
    if (path.startsWith('voices/')) return path.endsWith('.safetensors');
    return const {
      'config.json',
      'tokenizer.json',
      'tokenizer.model',
      'tokenizer_config.json',
      'tokenizer.5.0.0.json',
      'generation_config.json',
      'processor_config.json',
      'model.q8.gguf',
      'model.safetensors',
      'default-voice.safetensors',
      'README.md',
      'LICENSE',
      'LICENSE.txt',
      'LICENSE.md',
      'NOTICE',
    }.contains(path);
  }
}
