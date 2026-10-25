import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/phonon_model_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-phonon-model-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('imports a model folder zip into private app storage', () async {
    final zip = await _writeArchive(root, [
      ArchiveFile.string('phonon-31m-en/config.json', '{}'),
      ArchiveFile.string('phonon-31m-en/tokenizer.json', '{}'),
      ArchiveFile.string('phonon-31m-en/model.q8.gguf', 'weights'),
      ArchiveFile.string('phonon-31m-en/default-voice.safetensors', 'voice'),
    ]);

    final directory = await PhononModelStore.importCpuModelArchive(
      archivePath: zip.path,
      applicationSupportPath: root.path,
    );

    expect(File('$directory/config.json').readAsStringSync(), '{}');
    expect(File('$directory/tokenizer.json').readAsStringSync(), '{}');
    expect(File('$directory/model.q8.gguf').readAsStringSync(), 'weights');
    expect(
      File('$directory/default-voice.safetensors').readAsStringSync(),
      'voice',
    );
  });

  test(
    'rejects path traversal without writing outside the model folder',
    () async {
      final zip = await _writeArchive(root, [
        ArchiveFile.string('../outside.txt', 'not allowed'),
      ]);

      await expectLater(
        PhononModelStore.importCpuModelArchive(
          archivePath: zip.path,
          applicationSupportPath: root.path,
        ),
        throwsFormatException,
      );
      expect(File('${root.path}/outside.txt').existsSync(), isFalse);
    },
  );

  test('rejects archives without weights or a voice', () async {
    final zip = await _writeArchive(root, [
      ArchiveFile.string('config.json', '{}'),
      ArchiveFile.string('tokenizer.json', '{}'),
    ]);

    await expectLater(
      PhononModelStore.importCpuModelArchive(
        archivePath: zip.path,
        applicationSupportPath: root.path,
      ),
      throwsFormatException,
    );
  });
}

Future<File> _writeArchive(Directory root, List<ArchiveFile> files) async {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  final encoded = ZipEncoder().encode(archive);
  final file = File('${root.path}/model.zip');
  await file.writeAsBytes(encoded);
  return file;
}
