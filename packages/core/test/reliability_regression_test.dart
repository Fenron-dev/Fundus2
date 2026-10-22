import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FundusLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-reliability-');
    final folder = Directory('${root.path}/Manga/Original')
      ..createSync(recursive: true);
    File('${folder.path}/Chapter.cbz').writeAsBytesSync([1, 2, 3]);
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
  });
  tearDown(() async {
    await library.shutdown();
    await root.delete(recursive: true);
  });
  Future<void> rebuild() async {
    await library.shutdown();
    await File('${root.path}/.library/index.db').delete();
    library = await FundusLibrary.open(root);
    await library.index().drain<void>();
  }

  test(
    'unsafe backup extraction cannot escape its newly created vault',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'fundus-unsafe-backup-test-',
      );
      addTearDown(() => parent.delete(recursive: true));
      final malicious = Archive()
        ..addFile(ArchiveFile.string('../outside.txt', 'not allowed'));
      final file = File('${parent.path}/unsafe.zip');
      await file.writeAsBytes(ZipEncoder().encode(malicious));
      await expectLater(
        FundusLibrary.restoreBackup(file, parent),
        throwsFormatException,
      );
      expect(await File('${parent.path}/outside.txt').exists(), isFalse);
      expect((await parent.list().toList()).whereType<Directory>(), isEmpty);
    },
  );

  test(
    'pending metadata decisions survive reopening without a rescan',
    () async {
      final id = library.listWorks().single.id;
      final conflict = MetadataImportConflict(
        workId: id,
        workTitle: 'Test',
        sourcePath: 'fero.info.json',
        source: WorkMetadataSource.fero,
        fields: [
          MetadataFieldConflict(
            field: 'title',
            currentValue: 'Old',
            incomingValue: 'New',
          ),
        ],
      );
      await library.savePendingMetadataConflicts([conflict]);
      await library.shutdown();
      library = await FundusLibrary.open(root);
      final pending = await library.loadPendingMetadataConflicts();
      expect(pending.single.fields.single.incomingValue, 'New');
      await library.savePendingMetadataConflicts([]);
      expect(await library.loadPendingMetadataConflicts(), isEmpty);
    },
  );

  test('snapshot backup restores all personal rows into a new vault', () async {
    final parent = await Directory.systemTemp.createTemp(
      'fundus-restore-test-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final work = library.listWorks().single;
    final definition = await library.savePropertyDefinition(
      mediaKind: 'manga',
      name: 'Test',
      valueType: PropertyValueType.text,
    );
    await library.setWorkProperty(
      workId: work.id,
      definitionId: definition.id,
      value: 'Saved value',
    );
    final backup = File('${parent.path}/backup.zip');
    await library.backupTo(backup);
    final restored = await FundusLibrary.restoreBackup(backup, parent);
    final copy = await FundusLibrary.open(restored);
    try {
      expect(copy.manifest.libraryId, library.manifest.libraryId);
      expect(
        copy.loadWorkProperties(work.id)[definition.id]?.value,
        'Saved value',
      );
      expect(library.isUsable, isTrue);
    } finally {
      await copy.shutdown();
    }
  });

  test(
    'custom field definitions and values survive rebuilding only the index',
    () async {
      final id = library.listWorks().single.id;
      final definition = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Custom',
        valueType: PropertyValueType.tags,
        protected: true,
      );
      await library.setWorkProperty(
        workId: id,
        definitionId: definition.id,
        value: ['A', 'B'],
      );
      await rebuild();
      expect(library.listPropertyDefinitions().single.protected, isTrue);
      expect(library.loadWorkProperties(id)[definition.id]?.value, ['A', 'B']);
    },
  );
  test('checkpoint follows a moved work during an index rebuild', () async {
    final work = library.listWorks().single;
    final track = library.playbackTracks(work.id).single;
    library.saveMediaProgress(
      workId: work.id,
      fileId: track.fileId,
      position: MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 5,
        total: 25,
        fileId: track.fileId,
        scrollOffset: .8,
      ),
      checkpoint: true,
    );
    await library.flushSidecarWrites();
    await Directory(
      '${root.path}/Manga/Original',
    ).rename('${root.path}/Manga/Moved');
    await rebuild();
    expect(library.listWorks().single.id, work.id);
    expect(library.loadProgress(work.id)?.position.scrollOffset, .8);
  });
  test(
    'invalid and future progress never break a scan or rewind local state',
    () async {
      final work = library.listWorks().single;
      final track = library.playbackTracks(work.id).single;
      final file = File('${root.path}/Manga/Original/_fundus/progress.json');
      for (final position in [
        {'kind': 'future-format', 'numeric_value': 5},
        {'kind': 'imageIndex', 'numeric_value': 'wrong-type'},
      ]) {
        await file.writeAsString(
          jsonEncode({
            'format_version': 1,
            'file_path': track.relativePath,
            'position': position,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        await library.index(full: true).drain<void>();
        expect(library.listWorks(), hasLength(1));
      }
    },
  );
  test('peer annotations never create phantom media folders', () async {
    library.registerPeerSource(
      sourceId: 'peer-test',
      displayName: 'Remote',
      libraryId: 'remote',
      baseUrl: 'https://localhost',
    );
    final id = FundusId.generate();
    final fileId = FundusId.generate();
    library.mirrorRemoteCatalogue(
      sourceId: 'peer-test',
      works: [
        RemoteWorkRecord(
          id: id,
          kind: 'manga',
          title: 'Remote',
          files: [
            RemoteFileRecord(
              id: fileId,
              filename: 'Chapter.cbz',
              position: 0,
              extension: '.cbz',
            ),
          ],
        ),
      ],
    );
    await library.replaceWorkTags(id, ['Test']);
    library.saveProgress(
      workId: id,
      fileId: fileId,
      position: const Duration(seconds: 5),
      checkpoint: true,
    );
    await library.flushSidecarWrites();
    expect(Directory('${root.path}/peer').existsSync(), isFalse);
  });
  test(
    'schema 22 migrates with targeted lookup indexes and catalogue revision',
    () async {
      await library.shutdown();
      final db = FundusDatabase.openFile(
        File('${root.path}/.library/index.db'),
      );
      db.rawExecute('PRAGMA user_version = 22');
      db.rawExecute('DROP INDEX work_files_file_id_lookup');
      db.close();
      library = await FundusLibrary.open(root);
      final probe = FundusDatabase.openFile(
        File('${root.path}/.library/index.db'),
      );
      expect(probe.userVersion, FundusDatabase.schemaVersion);
      final plan = probe.rawQuery(
        'EXPLAIN QUERY PLAN SELECT * FROM work_files WHERE file_id = ?',
        ['x'],
      );
      expect(plan.toString(), contains('work_files_file_id_lookup'));
      probe.close();
    },
  );
  test('scroll and chapter changes affect the complete sync identity', () {
    const a = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 5,
      scrollOffset: .1,
    );
    const b = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 5,
      scrollOffset: .9,
    );
    expect(a.syncKey, isNot(b.syncKey));
  });
}
