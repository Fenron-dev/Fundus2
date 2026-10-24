import 'dart:io';
import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary, root;
  late FundusLibrary library;
  late String workId;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-history-');
    root = await Directory('${temporary.path}/vault').create();
    final folder = await Directory(
      '${root.path}/Karl May/Winnetou/01 - Winnetou I',
    ).create(recursive: true);
    await File('${folder.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    workId = library.listWorks().single.id;
  });
  tearDown(() async {
    await library.shutdown();
    await temporary.delete(recursive: true);
  });
  File historyFile() => File('${root.path}/_fundus/metadata-history.json');
  MetadataChangeBatch edit(String id) => MetadataChangeBatch(
    id: id,
    source: 'user',
    at: DateTime.utc(2026, 10, 24),
    changes: [
      MetadataFieldChange(
        workId: workId,
        field: 'title',
        before: MetadataFieldState(
          present: true,
          value: 'Book',
          source: 'filename',
        ),
        after: MetadataFieldState(
          present: true,
          value: id,
          source: 'user',
          locked: true,
        ),
      ),
    ],
  );

  test('concurrent appends are serialized without losing batches', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++)
        library.appendMetadataHistory(edit('edit-$i')),
    ]);
    final loaded = await library.loadMetadataHistory();
    expect(loaded.batches.map((batch) => batch.id), [
      for (var i = 0; i < 20; i++) 'edit-$i',
    ]);
    expect(await historyFile().exists(), isTrue);
  });

  test('shutdown waits for history and a reopened vault retains it', () async {
    final pending = library.appendMetadataHistory(edit('closing'));
    await library.shutdown();
    await pending;
    await expectLater(
      library.appendMetadataHistory(edit('after-close')),
      throwsStateError,
    );
    library = await FundusLibrary.open(root);
    expect((await library.loadMetadataHistory()).batches.single.id, 'closing');
  });

  test(
    'unknown and corrupted formats remain unchanged after failed append',
    () async {
      await historyFile().parent.create(recursive: true);
      for (final original in [
        '{"format_version":99,"private":"keep"}',
        'broken json',
      ]) {
        await historyFile().writeAsString(original);
        await expectLater(library.loadMetadataHistory(), throwsFormatException);
        await expectLater(
          library.appendMetadataHistory(edit('later')),
          throwsFormatException,
        );
        expect(await historyFile().readAsString(), original);
      }
      await historyFile().writeAsString(MetadataHistory().encode());
      await library.appendMetadataHistory(edit('repaired'));
      expect(
        (await library.loadMetadataHistory()).batches.single.id,
        'repaired',
      );
    },
  );

  test(
    'oversized files and non-file targets are refused without replacement',
    () async {
      await historyFile().parent.create(recursive: true);
      final handle = await historyFile().open(mode: FileMode.write);
      await handle.truncate(MetadataHistory.maxBytes + 1);
      await handle.close();
      await expectLater(
        library.appendMetadataHistory(edit('large')),
        throwsFormatException,
      );
      expect(await historyFile().length(), MetadataHistory.maxBytes + 1);
      await historyFile().delete();
      await Directory(historyFile().path).create();
      await expectLater(
        library.appendMetadataHistory(edit('directory')),
        throwsFormatException,
      );
      expect(await Directory(historyFile().path).exists(), isTrue);
    },
  );

  test(
    'symbolic history links cannot read or replace an outside file',
    () async {
      if (Platform.isWindows) {
        return; // Symlink creation requires host privileges.
      }
      await historyFile().parent.create(recursive: true);
      final outside = File('${temporary.path}/original.json');
      await outside.writeAsString('outside private data');
      await Link(historyFile().path).create(outside.path);
      await expectLater(library.loadMetadataHistory(), throwsFormatException);
      await expectLater(
        library.appendMetadataHistory(edit('linked')),
        throwsFormatException,
      );
      expect(await outside.readAsString(), 'outside private data');
      expect(await Link(historyFile().path).exists(), isTrue);
    },
  );

  test(
    'backup and restore include history without changing metadata or progress',
    () async {
      final originalTitle = library.workSummary(workId)!.title;
      final track = library.playbackTracks(workId).single;
      library.saveProgress(
        workId: workId,
        fileId: track.fileId,
        position: const Duration(seconds: 17),
      );
      await library.appendMetadataHistory(edit('history-only'));
      expect(library.workSummary(workId)!.title, originalTitle);
      expect(library.loadProgress(workId)!.position.numericValue, 17);
      final backup = File('${temporary.path}/backup.zip');
      await library.backupTo(backup);
      final restoredRoot = await FundusLibrary.restoreBackup(backup, temporary);
      final restored = await FundusLibrary.open(restoredRoot);
      try {
        expect(
          (await restored.loadMetadataHistory()).batches.single.id,
          'history-only',
        );
        expect(restored.workSummary(workId)!.title, originalTitle);
        expect(restored.loadProgress(workId)!.position.numericValue, 17);
      } finally {
        await restored.shutdown();
      }
    },
  );

  test('read-only vaults can inspect but cannot append history', () async {
    await library.appendMetadataHistory(edit('existing'));
    await library.shutdown();
    final manifest = library.manifest;
    await LibraryManifest(
      libraryId: manifest.libraryId,
      formatVersion: 2,
      minReaderVersion: 1,
      createdBy: manifest.createdBy,
    ).write(File('${root.path}/.library/version.json'));
    library = await FundusLibrary.open(root);
    expect(library.isReadOnly, isTrue);
    expect((await library.loadMetadataHistory()).batches.single.id, 'existing');
    final before = await historyFile().readAsString();
    await expectLater(
      library.appendMetadataHistory(edit('no-write')),
      throwsStateError,
    );
    expect(await historyFile().readAsString(), before);
    expect(jsonDecode(before)['format_version'], 3);
  });

  test('linked history folders cannot write outside the vault', () async {
    if (Platform.isWindows) return;
    await library.appendMetadataHistory(edit('original'));
    await library.flushSidecarWrites();
    final outside = await historyFile().parent.rename(
      '${temporary.path}/outside-history',
    );
    final original = await File(
      '${outside.path}/metadata-history.json',
    ).readAsString();
    await Link(historyFile().parent.path).create(outside.path);
    await expectLater(library.loadMetadataHistory(), throwsFormatException);
    await expectLater(
      library.appendMetadataHistory(edit('linked')),
      throwsFormatException,
    );
    expect(
      await File('${outside.path}/metadata-history.json').readAsString(),
      original,
    );
  });
}
