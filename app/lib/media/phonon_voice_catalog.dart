import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Phonon's shared voices.jsonl/custom.jsonl plus loose embeddings. The native
/// engine receives absolute references; large checkpoints are never duplicated.
final class PhononVoiceCatalog {
  static Future<List<Map<String, String>>> read(String? directory) async {
    if (directory == null || directory.trim().isEmpty) return const [];
    final root = Directory(directory);
    if (!await root.exists()) {
      throw const FormatException('Der Stimmenordner fehlt.');
    }
    final canonical = await root.resolveSymbolicLinks();
    final voices = <String, String>{};
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
        voices[label] = actual;
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
              voices[p.basenameWithoutExtension(entry.path)] = actual;
              if (voices.length > 2048) {
                throw const FormatException('Zu viele Stimmen im Ordner.');
              }
            }
          }
        }
      }
    }
    return [
      for (final entry in voices.entries)
        {'name': entry.key, 'path': entry.value},
    ];
  }
}
