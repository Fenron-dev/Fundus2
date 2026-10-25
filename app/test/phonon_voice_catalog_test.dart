import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/phonon_voice_catalog.dart';

void main() {
  test(
    'reads separate Phonon catalogues by name without copying files and refuses escape paths',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-voices-');
      addTearDown(() => root.delete(recursive: true));
      final voices = Directory('${root.path}/shared')..createSync();
      Directory('${voices.path}/voices').createSync();
      File(
        '${voices.path}/voices/english.safetensors',
      ).writeAsStringSync('embedding');
      File('${root.path}/outside.safetensors').writeAsStringSync('outside');
      File('${voices.path}/voices.jsonl').writeAsStringSync(
        [
          jsonEncode({
            'name': 'English narrator',
            'filename': 'voices/english.safetensors',
          }),
          jsonEncode({'name': 'Outside', 'filename': '../outside.safetensors'}),
          jsonEncode({
            'name': 'Missing',
            'filename': 'voices/missing.safetensors',
          }),
        ].join('\n'),
      );
      final found = await PhononVoiceCatalog.read(voices.path);
      expect(found, [
        {
          'name': 'English narrator',
          'path': File(
            '${voices.path}/voices/english.safetensors',
          ).resolveSymbolicLinksSync(),
        },
      ]);
      expect(root.listSync(recursive: true).whereType<File>().length, 3);
    },
  );
}
