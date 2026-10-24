import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FundusLibrary library;
  late String id, secondId;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-history-capture-');
    for (final title in ['01 - First', '02 - Second']) {
      final folder = await Directory(
        '${root.path}/Karl May/Winnetou/$title',
      ).create(recursive: true);
      await File('${folder.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final works = library.listWorks();
    id = works.firstWhere((work) => work.title == 'First').id;
    secondId = works.firstWhere((work) => work.title == 'Second').id;
  });
  tearDown(() async {
    await library.shutdown();
    await root.delete(recursive: true);
  });
  MetadataHistory history() => library.indexedMetadataHistory(
    visibleWorkIds: {id, secondId},
    includeProtected: true,
  );
  Future<void> title(String value, {String? workId}) async {
    await library.updateWorkMetadata(
      workId: workId ?? id,
      title: value,
      authors: ['Karl May'],
    );
  }

  FundusDatabase probe() =>
      FundusDatabase.openFile(File('${root.path}/.library/index.db'));

  test(
    'cover versions restore the exact earlier picture without touching media',
    () async {
      final first = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final second = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List.fromList([4, 5, 6]),
      );
      expect(first, isNot(second));
      expect(library.workSummary(id)!.coverPath, second);
      final batch = history().batches.last;
      final cover = batch.changes.singleWhere(
        (change) => change.field == 'cover',
      );
      expect(MetadataImageVersion.inState(cover.before.value), isNotNull);
      await library.undoMetadataBatch(
        batch.id,
        visibleWorkIds: {id},
        selectedKeys: {cover.key},
      );
      expect(library.workSummary(id)!.coverPath, first);
      expect(await File(first).readAsBytes(), [1, 2, 3]);
      expect(await File(second).readAsBytes(), [4, 5, 6]);
      await library.shutdown();
      library = await FundusLibrary.open(root);
      await library.index().drain<void>();
      expect(library.workSummary(id)!.coverPath, first);
    },
  );

  test(
    'missing prior picture blocks undo without changing the current choice',
    () async {
      final first = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final second = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List.fromList([4, 5, 6]),
      );
      final batch = history().batches.last;
      final cover = batch.changes.singleWhere(
        (change) => change.field == 'cover',
      );
      await File(first).delete();
      await expectLater(
        library.undoMetadataBatch(
          batch.id,
          visibleWorkIds: {id},
          selectedKeys: {cover.key},
        ),
        throwsA(anything),
      );
      expect(library.workSummary(id)!.coverPath, second);
      expect(history().batches.last.id, batch.id);
    },
  );

  test(
    'a folder cover stays untouched when an imported cover is chosen and undone',
    () async {
      final folderCover = File(
        '${root.path}/Karl May/Winnetou/01 - First/cover.png',
      );
      await folderCover.writeAsBytes([7, 8, 9]);
      await library.index().drain<void>();
      final original = library.workSummary(id)!.coverPath;
      expect(original, folderCover.path);
      await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(library.workSummary(id)!.coverPath, original);
      await library.setCoverPreference(id, generated: true);
      final changed = library.workSummary(id)!.coverPath;
      expect(changed, isNot(original));
      final batch = history().batches.last;
      final cover = batch.changes.singleWhere(
        (change) => change.field == 'cover',
      );
      await library.undoMetadataBatch(
        batch.id,
        visibleWorkIds: {id},
        selectedKeys: {cover.key},
      );
      final restored = library.workSummary(id)!.coverPath!;
      expect(
        restored,
        contains(
          '${Platform.pathSeparator}.library${Platform.pathSeparator}covers${Platform.pathSeparator}versions${Platform.pathSeparator}',
        ),
      );
      expect(await File(restored).readAsBytes(), [7, 8, 9]);
      expect(await folderCover.readAsBytes(), [7, 8, 9]);
      expect(await File(changed!).readAsBytes(), [1, 2, 3]);
    },
  );

  test('a changed folder image cannot reuse an older image proof', () async {
    final folderCover = File(
      '${root.path}/Karl May/Winnetou/01 - First/cover.png',
    );
    await folderCover.writeAsBytes([7, 8, 9]);
    await library.index().drain<void>();
    await library.cacheGeneratedCover(
      workId: id,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await library.setCoverPreference(id, generated: true);
    await library.setCoverPreference(id, generated: false);
    final db = probe();
    expect(
      MetadataImageVersion.inState(db.metadataFieldStates(id)!['cover']!.value),
      isNotNull,
    );
    db.close();
    await folderCover.writeAsBytes([4, 5, 6, 7]);
    await library.index().drain<void>();
    final after = probe();
    expect(
      MetadataImageVersion.inState(
        after.metadataFieldStates(id)!['cover']!.value,
      ),
      isNull,
    );
    after.close();
    expect(await folderCover.readAsBytes(), [4, 5, 6, 7]);
  });

  test(
    'image quota expires whole old batches but keeps current and undoable pictures',
    () async {
      await library.setMetadataHistoryPolicy(
        const MetadataHistoryPolicy(imageBudget: 1024 * 1024),
      );
      final first = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List(700000)..fillRange(0, 700000, 1),
      );
      final second = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List(700000)..fillRange(0, 700000, 2),
      );
      final third = await library.cacheGeneratedCover(
        workId: id,
        bytes: Uint8List(700000)..fillRange(0, 700000, 3),
      );
      expect(history().batches, hasLength(1));
      expect(await File(first).exists(), isFalse);
      expect(await File(second).exists(), isTrue);
      expect(await File(third).exists(), isTrue);
      final snapshot = await library.loadMetadataHistory();
      expect(snapshot.policy.imageBudget, 1024 * 1024);
      expect(snapshot.batches, hasLength(1));
    },
  );

  test(
    'authors roll back as one coherent field, including the primary author',
    () async {
      final original = library.workSummary(id)!;
      await library.updateWorkMetadata(
        workId: id,
        title: 'First',
        authors: ['New primary', 'Another'],
      );
      final batch = history().batches.single;
      expect(batch.changes.any((change) => change.field == 'author'), isFalse);
      final authors = batch.changes.singleWhere(
        (change) => change.field == 'authors',
      );
      await library.undoMetadataBatch(
        batch.id,
        visibleWorkIds: {id},
        selectedKeys: {authors.key},
      );
      expect(library.workSummary(id)!.authors, original.authors);
      expect(library.workSummary(id)!.author, original.author);
    },
  );

  test(
    'a batch extended after preview cannot be undone using stale expected values',
    () async {
      await MetadataEditBatch.run(
        source: 'user',
        action: () async {
          await title('Previewed');
          final before = history().batches.single;
          final expected = before.changes.singleWhere(
            (change) => change.field == 'title',
          );
          await title('Added later in the same batch');
          await expectLater(
            library.undoMetadataBatch(
              before.id,
              visibleWorkIds: {id},
              selectedKeys: {expected.key},
              expectedAfter: {expected.key: expected.after},
            ),
            throwsStateError,
          );
          expect(
            library.workSummary(id)!.title,
            'Added later in the same batch',
          );
        },
      );
    },
  );

  test(
    'selected undo restores exact origin and records an undo that can itself be undone',
    () async {
      await title('Corrected');
      final original = history().batches.single;
      final change = original.changes.singleWhere(
        (change) => change.field == 'title',
      );
      await library.undoMetadataBatch(
        original.id,
        visibleWorkIds: {id},
        selectedKeys: {change.key},
      );
      expect(library.workSummary(id)!.title, 'First');
      final origin = library.workSummary(id)!.metadataOrigins['title']!;
      expect(origin.source.name, change.before.source);
      expect(origin.updatedAt, change.before.originAt);
      final undo = history().batches.last;
      expect(undo.reversesBatchId, original.id);
      await library.undoMetadataBatch(
        undo.id,
        visibleWorkIds: {id},
        selectedKeys: {change.key},
      );
      expect(library.workSummary(id)!.title, 'Corrected');
    },
  );

  test(
    'a newer edit blocks the whole selected rollback, but an explicit other field can be undone',
    () async {
      await library.updateWorkMetadata(
        workId: id,
        title: 'Matched',
        authors: ['Karl May'],
        genres: ['Fantasy'],
      );
      final original = history().batches.single;
      await title('Newer correction');
      final keys = original.changes
          .where((change) => ['title', 'genres'].contains(change.field))
          .map((change) => change.key)
          .toSet();
      await expectLater(
        library.undoMetadataBatch(
          original.id,
          visibleWorkIds: {id},
          selectedKeys: keys,
        ),
        throwsA(isA<MetadataUndoConflictException>()),
      );
      expect(library.workSummary(id)!.title, 'Newer correction');
      expect(library.workSummary(id)!.genres, ['Fantasy']);
      final genre = original.changes.singleWhere(
        (change) => change.field == 'genres',
      );
      await library.undoMetadataBatch(
        original.id,
        visibleWorkIds: {id},
        selectedKeys: {genre.key},
      );
      expect(library.workSummary(id)!.title, 'Newer correction');
      expect(library.workSummary(id)!.genres, isEmpty);
    },
  );

  test(
    'multi-work undo is atomic and invisible works cannot be included',
    () async {
      await MetadataEditBatch.run(
        source: 'user:batch',
        action: () async {
          await title('One');
          await title('Two', workId: secondId);
        },
      );
      final original = history().batches.single;
      await title('Newer second', workId: secondId);
      final keys = original.changes
          .where((change) => change.field == 'title')
          .map((change) => change.key)
          .toSet();
      await expectLater(
        library.undoMetadataBatch(
          original.id,
          visibleWorkIds: {id, secondId},
          selectedKeys: keys,
        ),
        throwsA(isA<MetadataUndoConflictException>()),
      );
      expect(library.workSummary(id)!.title, 'One');
      await library.undoMetadataBatch(
        original.id,
        visibleWorkIds: {id},
        selectedKeys: keys,
      );
      expect(library.workSummary(id)!.title, 'First');
      expect(library.workSummary(secondId)!.title, 'Newer second');
    },
  );

  test(
    'property, tags and status undo leaves progress, votes and notes untouched',
    () async {
      final field = await library.savePropertyDefinition(
        mediaKind: '',
        name: 'Speaker',
        valueType: PropertyValueType.text,
      );
      await library.setWorkProperty(
        workId: id,
        definitionId: field.id,
        value: 'Before',
      );
      final before = library.loadWorkProperties(id)[field.id]!;
      await MetadataEditBatch.run(
        source: 'user',
        action: () async {
          await library.setWorkProperty(
            workId: id,
            definitionId: field.id,
            value: 'After',
          );
          await library.setWorkStatuses(
            workId: id,
            publicationStatus: 'completed',
          );
          await library.replaceWorkTags(id, ['Fantasy']);
        },
      );
      final original = history().batches.last;
      final file = library.playbackTracks(id).single.fileId;
      library.saveProgress(
        workId: id,
        fileId: file,
        position: const Duration(seconds: 75),
      );
      await library.setRating(workId: id, fileId: file, value: 1);
      await library.saveWorkNote(id, 'Keep this note');
      await library.undoMetadataBatch(
        original.id,
        visibleWorkIds: {id},
        selectedKeys: original.changes.map((change) => change.key).toSet(),
        includeProtected: true,
      );
      expect(library.loadWorkProperties(id)[field.id]!.value, 'Before');
      expect(
        library.loadWorkProperties(id)[field.id]!.updatedAt,
        before.updatedAt,
      );
      expect(library.workSummary(id)!.publicationStatus, 'unknown');
      expect(library.loadAnnotations(id).tags, isEmpty);
      expect(library.loadProgress(id)!.position.numericValue, 75);
      expect(library.loadAnnotations(id).ratings.single.value, 1);
      expect(
        library.loadAnnotations(id).notes.single.markdown,
        'Keep this note',
      );
    },
  );

  test(
    'removed property definitions prevent rollback instead of silently losing values',
    () async {
      final field = await library.savePropertyDefinition(
        mediaKind: '',
        name: 'Field',
        valueType: PropertyValueType.text,
      );
      await MetadataEditBatch.run(
        source: 'user',
        action: () async {
          await title('After');
          await library.setWorkProperty(
            workId: id,
            definitionId: field.id,
            value: 'After',
          );
        },
      );
      final original = history().batches.single;
      await library.deletePropertyDefinition(field.id);
      await expectLater(
        library.undoMetadataBatch(
          original.id,
          visibleWorkIds: {id},
          selectedKeys: original.changes.map((change) => change.key).toSet(),
        ),
        throwsA(isA<MetadataUndoConflictException>()),
      );
      expect(library.workSummary(id)!.title, 'After');
    },
  );

  test(
    'history captured while protected stays hidden after reclassification',
    () async {
      await library.updateWorkKind(
        workId: id,
        kind: 'audiobook',
        contentSensitivity: 'adult_explicit',
      );
      await title('Private historical title');
      final private = history().batches.last;
      await library.updateWorkKind(
        workId: id,
        kind: 'audiobook',
        contentSensitivity: 'general',
      );
      final public = library.indexedMetadataHistory(visibleWorkIds: {id});
      expect(public.batches.any((batch) => batch.id == private.id), isFalse);
      final plan = library.previewMetadataUndo(
        private.id,
        visibleWorkIds: {id},
      );
      expect(plan.applicable, isEmpty);
      expect(plan.conflicts, isEmpty);
    },
  );

  test(
    'actual edits record before, after and manual ownership atomically',
    () async {
      await title('Corrected');
      final change = history().batches.single.changes.firstWhere(
        (change) => change.field == 'title',
      );
      expect(change.before.value, 'First');
      expect(change.after.value, 'Corrected');
      expect(change.after.source, 'user');
      expect(change.after.locked, isTrue);
      expect(
        (await library.loadMetadataHistory()).encode(),
        history().encode(),
      );
      await title('Corrected');
      expect(history().batches, hasLength(1));
    },
  );

  test(
    'one async logical edit combines works and preserves the earliest before value',
    () async {
      await MetadataEditBatch.run(
        source: 'user:batch',
        action: () async {
          await title('Intermediate');
          await Future<void>.delayed(Duration.zero);
          await title('Final');
          await title('Other final', workId: secondId);
          expect(history().batches, hasLength(1));
        },
      );
      final batch = history().batches.single;
      expect(batch.source, 'user:batch');
      final changes = batch.changes
          .where((change) => change.field == 'title')
          .toList();
      expect(changes, hasLength(2));
      expect(changes.first.before.value, 'First');
      expect(changes.first.after.value, 'Final');
      expect((await library.loadMetadataHistory()).batches.single.id, batch.id);
    },
  );

  test(
    'partial failure keeps exactly the committed steps and flushes their batch',
    () async {
      await expectLater(
        MetadataEditBatch.run(
          source: 'user',
          action: () async {
            await title('Committed');
            throw StateError('later image failed');
          },
        ),
        throwsStateError,
      );
      expect(library.workSummary(id)!.title, 'Committed');
      expect(
        (await library.loadMetadataHistory()).batches.single.changes.any(
          (change) => change.after.value == 'Committed',
        ),
        isTrue,
      );
    },
  );

  test(
    'ledger insertion failure rolls back the edit and its search update',
    () async {
      final db = probe();
      db.rawExecute(
        "CREATE TRIGGER reject_test_history BEFORE INSERT ON metadata_history_batches BEGIN SELECT RAISE(ABORT, 'history unavailable'); END",
      );
      db.close();
      await expectLater(title('Must not commit'), throwsA(isA<Object>()));
      expect(library.workSummary(id)!.title, 'First');
      expect(history().batches, isEmpty);
      final after = probe();
      try {
        expect(
          after.rawQuery(
            "SELECT title FROM search_index WHERE entity_type = 'work' AND entity_id = ?",
            [id],
          ).single['title'],
          'First',
        );
      } finally {
        after.close();
      }
    },
  );

  test('nested tag transactions roll back with the outer metadata failure', () {
    final db = probe();
    try {
      expect(
        () => db.recordMetadataMutation(
          workId: id,
          source: 'user',
          action: () {
            db.replaceWorkTags(id, ['must roll back']);
            throw StateError('abort whole edit');
          },
        ),
        throwsStateError,
      );
      expect(db.loadAnnotations(id).tags, isEmpty);
      expect(db.metadataHistorySnapshot().history.batches, isEmpty);
      db.transaction(() {
        db.replaceWorkTags(id, ['outer']);
        try {
          db.transaction(() {
            db.replaceWorkTags(id, ['inner']);
            throw StateError('inner only');
          });
        } on StateError {
          // The outer operation can continue after a rolled-back savepoint.
        }
      });
      expect(db.loadAnnotations(id).tags, ['outer']);
    } finally {
      db.close();
    }
  });

  test(
    'progress, votes, notes and bookmarks do not enter metadata history',
    () async {
      final fileId = library.playbackTracks(id).single.fileId;
      await MetadataEditBatch.run(
        source: 'user',
        action: () async {
          await title('New title');
          // This would fail with a nested BEGIN if an edit held SQLite open
          // across the await above. It must remain an independent progress write.
          library.saveProgress(
            workId: id,
            fileId: fileId,
            position: const Duration(seconds: 23),
          );
          await library.saveWorkNote(id, 'private note');
        },
      );
      expect(library.loadProgress(id)!.position.numericValue, 23);
      expect(library.loadAnnotations(id).notes.single.markdown, 'private note');
      expect(
        history().batches.single.changes.every(
          (change) => !['progress', 'notes', 'rating'].contains(change.field),
        ),
        isTrue,
      );
    },
  );

  test(
    'statuses, tags and properties are captured; personal star fields are excluded',
    () async {
      final field = await library.savePropertyDefinition(
        mediaKind: '',
        name: 'Translator',
        valueType: PropertyValueType.text,
      );
      final rating = await library.savePropertyDefinition(
        mediaKind: '',
        name: 'My stars',
        valueType: PropertyValueType.rating,
      );
      await MetadataEditBatch.run(
        source: 'user',
        action: () async {
          await library.setWorkStatuses(
            workId: id,
            publicationStatus: 'completed',
            personalStatus: 'paused',
          );
          await library.replaceWorkTags(id, ['Fantasy', 'Drama']);
          await library.setWorkProperty(
            workId: id,
            definitionId: field.id,
            value: 'Person',
          );
          await library.setWorkProperty(
            workId: id,
            definitionId: rating.id,
            value: 4,
          );
        },
      );
      final fields = history().batches.single.changes
          .map((change) => change.field)
          .toSet();
      expect(
        fields,
        containsAll([
          'publication_status',
          'personal_status',
          'tags',
          'property:${field.id}',
        ]),
      );
      expect(fields, isNot(contains('property:${rating.id}')));
      final hidden = library.indexedMetadataHistory(
        visibleWorkIds: {id},
        protectedPropertyIds: {field.id},
      );
      expect(
        hidden.batches.single.changes.any(
          (change) => change.field == 'property:${field.id}',
        ),
        isFalse,
      );
      expect(
        library.indexedMetadataHistory(visibleWorkIds: {}).batches,
        isEmpty,
      );
    },
  );

  test(
    'failed portable export preserves committed index history and recovers after restart',
    () async {
      final file = File('${root.path}/_fundus/metadata-history.json');
      await file.parent.create(recursive: true);
      const newer = '{"format_version":99,"private":"keep"}';
      await file.writeAsString(newer);
      await title('Saved despite offline history copy');
      expect(
        library.workSummary(id)!.title,
        'Saved despite offline history copy',
      );
      expect(history().batches, hasLength(1));
      expect(library.metadataHistoryError, isNotNull);
      expect(await file.readAsString(), newer);
      await library.shutdown();
      // Explicitly repair the unknown portable document, without deleting index data.
      await file.writeAsString(MetadataHistory().encode());
      library = await FundusLibrary.open(root);
      expect(library.metadataHistoryError, isNull);
      expect((await library.loadMetadataHistory()).batches, hasLength(1));
    },
  );

  test(
    'schema 24 migrates without losing values, progress or portable history',
    () async {
      await title('Before migration');
      final fileId = library.playbackTracks(id).single.fileId;
      library.saveProgress(
        workId: id,
        fileId: fileId,
        position: const Duration(seconds: 42),
      );
      await library.shutdown();
      final db = probe();
      db.rawExecute('DROP TABLE metadata_image_refs');
      db.rawExecute('DROP TABLE metadata_history_batches');
      db.rawExecute('DROP TABLE metadata_history_state');
      db.rawExecute('PRAGMA user_version = 24');
      db.close();
      library = await FundusLibrary.open(root);
      expect(library.workSummary(id)!.title, 'Before migration');
      expect(library.loadProgress(id)!.position.numericValue, 42);
      expect(history().batches, hasLength(1));
      expect(
        jsonDecode(
          await File(
            '${root.path}/_fundus/metadata-history.json',
          ).readAsString(),
        )['format_version'],
        3,
      );
    },
  );
}
