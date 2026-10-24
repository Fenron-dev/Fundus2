import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/src/library/metadata_image_store.dart';
import 'package:fundus_core/src/model/metadata_image.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary, root;
  late MetadataImageStore store;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-image-versions-');
    root = await Directory('${temporary.path}/vault').create();
    store = MetadataImageStore(root);
  });
  tearDown(() => temporary.delete(recursive: true));

  test(
    'folder source is only read and immutable copy verifies its digest',
    () async {
      final source = File('${root.path}/cover.png');
      await source.writeAsBytes([1, 2, 3]);
      final version = await store.snapshot('cover.png', role: 'cover');
      expect(await store.verify(version), [1, 2, 3]);
      await source.writeAsBytes([4, 5, 6]);
      expect(await source.readAsBytes(), [4, 5, 6]);
      expect(await store.verify(version), [1, 2, 3]);
      await expectLater(
        store.snapshot('../other.png', role: 'cover'),
        throwsFormatException,
      );
    },
  );

  test(
    'collection preserves referenced copies and ignores unrelated names',
    () async {
      final kept = await store.store(Uint8List.fromList([1]), role: 'cover');
      final old = await store.store(Uint8List.fromList([2]), role: 'cover');
      final folder = Directory(
        '${root.path}/${MetadataImageVersion.directory}',
      );
      final unrelated = File('${folder.path}/notes.txt');
      await unrelated.writeAsString('keep');
      final result = await store.collect({kept.path});
      expect(result.files, 1);
      expect(await store.verify(kept), [1]);
      expect(await File('${root.path}/${old.path}').exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test('only old private partial files are removed', () async {
    final version = await store.store(Uint8List.fromList([1]), role: 'cover');
    final target = File('${root.path}/${version.path}');
    final oldPart = File(
      '${target.path}.12345678-1234-1234-1234-123456789abc.part',
    );
    final freshPart = File(
      '${target.path}.abcdef12-1234-1234-1234-123456789abc.part',
    );
    await oldPart.writeAsBytes([3]);
    await oldPart.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    await freshPart.writeAsBytes([4]);
    await store.collect({version.path});
    expect(await oldPart.exists(), isFalse);
    expect(await freshPart.exists(), isTrue);
    expect(await target.exists(), isTrue);
  });

  test('links cannot redirect images outside the vault', () async {
    if (Platform.isWindows) return;
    final outside = File('${temporary.path}/private.png');
    await outside.writeAsBytes([9, 8, 7]);
    await Link('${root.path}/cover.png').create(outside.path);
    await expectLater(
      store.snapshot('cover.png', role: 'cover'),
      throwsA(anything),
    );
    expect(await outside.readAsBytes(), [9, 8, 7]);

    final versions = Directory(
      '${root.path}/${MetadataImageVersion.directory}',
    );
    await versions.parent.create(recursive: true);
    await Link(versions.path).create(temporary.path);
    await expectLater(
      store.store(Uint8List.fromList([1]), role: 'cover'),
      throwsA(anything),
    );
    expect(await outside.readAsBytes(), [9, 8, 7]);
  });
}
