import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

final class PhononVoiceInfo {
  const PhononVoiceInfo({
    required this.name,
    required this.path,
    this.language,
    this.locale,
    this.gender,
  });

  final String name;
  final String path;
  final String? language;
  final String? locale;
  final String? gender;

  String get displayLabel {
    final parts = <String>[];
    if (gender == 'female') {
      parts.add('weiblich');
    } else if (gender == 'male') {
      parts.add('männlich');
    }
    final languageName = switch (language?.toLowerCase()) {
      'de' => 'Deutsch',
      'en' => 'Englisch',
      'fr' => 'Französisch',
      'es' => 'Spanisch',
      'pt' => 'Portugiesisch',
      _ => language,
    };
    if (languageName?.trim().isNotEmpty ?? false) parts.add(languageName!);
    if (locale?.trim().isNotEmpty ?? false) {
      final accent = switch (locale!.toLowerCase()) {
        'en-us' => 'US-Akzent',
        'en-gb' => 'UK-Akzent',
        'en-au' => 'Australischer Akzent',
        'de-de' => 'Deutschland',
        'de-at' => 'Österreich',
        'de-ch' => 'Schweiz',
        _ => locale!,
      };
      parts.add(accent);
    }
    return parts.isEmpty ? name : '$name (${parts.join(' · ')})';
  }
}

/// Phonon's shared voices.jsonl/custom.jsonl plus loose embeddings. The native
/// engine receives absolute references; large checkpoints are never duplicated.
final class PhononVoiceCatalog {
  static Future<List<Map<String, String>>> read(String? directory) async {
    final detailed = await readDetailed(directory);
    return [
      for (final voice in detailed) {'name': voice.name, 'path': voice.path},
    ];
  }

  static Future<List<PhononVoiceInfo>> readDetailed(String? directory) async {
    if (directory == null || directory.trim().isEmpty) return const [];
    final root = Directory(directory);
    if (!await root.exists()) {
      throw const FormatException('Der Stimmenordner fehlt.');
    }
    final canonical = await root.resolveSymbolicLinks();
    final voices = <String, PhononVoiceInfo>{};
    for (final name in ['voices.jsonl', 'custom.jsonl']) {
      final file = File(p.join(directory, name));
      if (!await file.exists()) continue;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Der Stimmenkatalog ist zu groß.');
      }
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final entry = jsonDecode(line);
        if (entry is! Map || entry['filename'] is! String) continue;
        final relative = entry['filename'] as String;
        final label = entry['name'] ?? entry['voice_id'];
        if (label is! String ||
            label.trim().isEmpty ||
            label.length > 256 ||
            label.contains('\u0000') ||
            p.isAbsolute(relative)) {
          continue;
        }
        final target = File(p.normalize(p.join(directory, relative)));
        if (!await target.exists()) continue;
        final actual = await target.resolveSymbolicLinks();
        if (!p.isWithin(canonical, actual)) continue;
        final language = entry['language'];
        final locale = entry['locale'];
        final gender = entry['gender'];
        voices[label] = PhononVoiceInfo(
          name: label,
          path: actual,
          language: language is String ? language : null,
          locale: locale is String ? locale : null,
          gender: gender is String ? gender.toLowerCase() : null,
        );
        if (voices.length > 2048) {
          throw const FormatException('Zu viele Stimmen im Katalog.');
        }
      }
    }
    if (voices.isEmpty) {
      // A folder without a catalogue can still contain individually named voices.
      for (final folder in [
        root,
        Directory(p.join(directory, 'voices')),
        Directory(p.join(directory, 'custom')),
      ]) {
        if (!await folder.exists()) continue;
        await for (final entry in folder.list(followLinks: false)) {
          if (entry is File &&
              p.extension(entry.path) == '.safetensors' &&
              !p.basename(entry.path).startsWith('model')) {
            final actual = await entry.resolveSymbolicLinks();
            if (p.isWithin(canonical, actual)) {
              final name = p.basenameWithoutExtension(entry.path);
              voices[name] = PhononVoiceInfo(name: name, path: actual);
              if (voices.length > 2048) {
                throw const FormatException('Zu viele Stimmen im Ordner.');
              }
            }
          }
        }
      }
    }
    return [...voices.values];
  }
}
