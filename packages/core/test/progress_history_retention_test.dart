import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Progress history is a record of where people stopped, not a log of every
/// autosave. Read aloud, Fundus saves once per sentence; the history has to
/// stay small without forgetting what anybody asks it for.
void main() {
  FundusDatabase openWithWork() {
    final database = FundusDatabase.inMemory();
    database.rawExecute(
      'INSERT INTO works (id, source_id, kind, source_path, title, added_at, '
      "status) VALUES ('w1', ?, 'audiobook', 'Buch', 'Ein Buch', 0, "
      "'available')",
      [FundusDatabase.localSourceId],
    );
    database.rawExecute(
      'INSERT INTO files (id, source_id, path, filename, size, '
      "file_modified_at, indexed_at) VALUES ('f1', ?, 'Buch/01.mp3', "
      "'01.mp3', 1, 0, 0)",
      [FundusDatabase.localSourceId],
    );
    return database;
  }

  LibraryPlaybackProgress save(
    FundusDatabase database, {
    required double seconds,
    String device = 'phone',
    bool checkpoint = false,
    String? operationId,
  }) => database.saveMediaProgress(
    workId: 'w1',
    fileId: 'f1',
    position: MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: seconds,
      fileId: 'f1',
    ),
    finished: false,
    deviceId: device,
    operationId: operationId ?? FundusId.generate(),
    checkpoint: checkpoint,
  );

  int rowCount(FundusDatabase database, String table) =>
      database.rawQuery('SELECT COUNT(*) AS n FROM $table').first['n'] as int;

  test('a long listening session leaves a bounded history', () {
    final database = openWithWork();
    addTearDown(database.close);
    save(database, seconds: 1, device: 'desktop', checkpoint: true);
    for (var sentence = 0; sentence < 600; sentence++) {
      save(
        database,
        seconds: 10.0 + sentence,
        // Like the reader: a checkpoint every few sentences.
        checkpoint: sentence % 5 == 0,
      );
    }

    final revisions = database.listProgressRevisions('w1');
    expect(
      revisions.length,
      lessThanOrEqualTo(
        FundusDatabase.progressAutosavesKept +
            FundusDatabase.progressCheckpointsKeptPerDevice +
            2,
      ),
    );
    // The current position is the newest row and survives.
    expect(revisions.first.revision, 601);
    expect(database.loadProgress('w1')!.position.numericValue, 609);
    // The other device's only row is where it stands, so it stays.
    expect(
      revisions.where((revision) => revision.deviceId == 'desktop'),
      hasLength(1),
    );
    expect(
      revisions.where(
        (revision) => revision.deviceId == 'phone' && revision.checkpoint,
      ),
      hasLength(FundusDatabase.progressCheckpointsKeptPerDevice),
    );
  });

  test('stop points are listed newest first and per device', () {
    final database = openWithWork();
    addTearDown(database.close);
    for (var index = 0; index < 6; index++) {
      save(database, seconds: 100.0 + index, checkpoint: true);
      save(
        database,
        seconds: 200.0 + index,
        device: 'desktop',
        checkpoint: true,
      );
      save(database, seconds: 300.0 + index);
    }

    final listed = database.listCheckpointRevisions('w1');
    expect(listed, hasLength(6));
    expect(listed.every((revision) => revision.checkpoint), isTrue);
    expect(
      listed
          .where((revision) => revision.deviceId == 'phone')
          .map((revision) => revision.position.numericValue),
      [105, 104, 103],
    );
    expect(
      listed
          .where((revision) => revision.deviceId == 'desktop')
          .map((revision) => revision.position.numericValue),
      [205, 204, 203],
    );
    final revisions = [for (final revision in listed) revision.revision];
    expect(revisions, [...revisions]..sort((a, b) => b.compareTo(a)));
  });

  test('a retried write still counts once after its row is gone', () {
    final database = openWithWork();
    addTearDown(database.close);
    save(database, seconds: 5, operationId: 'retried-operation');
    for (var index = 0; index < 60; index++) {
      save(database, seconds: 10.0 + index);
    }
    expect(
      database
          .listProgressRevisions('w1')
          .where((revision) => revision.operationId == 'retried-operation'),
      isEmpty,
    );

    final answer = save(database, seconds: 5, operationId: 'retried-operation');
    expect(answer.revision, 61);
    expect(answer.position.numericValue, 69);
  });

  test('remembered operations are forgotten after a while', () {
    final database = openWithWork();
    addTearDown(database.close);
    final old = DateTime.now()
        .subtract(
          FundusDatabase.progressOperationMemory + const Duration(days: 1),
        )
        .millisecondsSinceEpoch;
    database.rawExecute(
      'INSERT INTO progress_operations (operation_id, seen_at) VALUES (?, ?)',
      ['ancient', old],
    );
    save(database, seconds: 1);
    expect(rowCount(database, 'progress_operations'), 0);
  });

  test('restoring a revision reads only that revision', () {
    final database = openWithWork();
    addTearDown(database.close);
    save(database, seconds: 42, checkpoint: true);
    save(database, seconds: 50);
    final restored = database.restoreProgressRevision(
      workId: 'w1',
      revision: 1,
      deviceId: 'desktop',
      operationId: 'restore-1',
    );
    expect(restored.revision, 3);
    expect(restored.position.numericValue, 42);
    expect(
      () => database.restoreProgressRevision(
        workId: 'w1',
        revision: 99,
        deviceId: 'desktop',
        operationId: 'restore-2',
      ),
      throwsStateError,
    );
  });

  test('schema 26 migrates and prunes an overgrown history', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v26-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final current = FundusDatabase.openFile(file);
    current.rawExecute(
      'INSERT INTO works (id, source_id, kind, source_path, title, added_at, '
      "status) VALUES ('w1', ?, 'audiobook', 'Buch', 'Ein Buch', 0, "
      "'available')",
      [FundusDatabase.localSourceId],
    );
    current.rawExecute(
      'INSERT INTO files (id, source_id, path, filename, size, '
      "file_modified_at, indexed_at) VALUES ('f1', ?, 'Buch/01.mp3', "
      "'01.mp3', 1, 0, 0)",
      [FundusDatabase.localSourceId],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var revision = 1; revision <= 500; revision++) {
      current.rawExecute(
        'INSERT INTO progress_revisions (work_id, user_id, revision, '
        'operation_id, snapshot_json, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          'w1',
          'default',
          revision,
          'operation-$revision',
          jsonEncode({
            'work_id': 'w1',
            'position': {
              'kind': 'time',
              'numeric_value': revision,
              'file_id': 'f1',
            },
            'finished': false,
            'device_id': revision.isEven ? 'phone' : 'desktop',
            'checkpoint': revision % 50 == 0,
          }),
          // The first half is older than anybody would still retry.
          revision <= 250 ? 0 : now,
        ],
      );
    }
    // One row that is not JSON at all must not stop the upgrade.
    current.rawExecute(
      'INSERT INTO progress_revisions (work_id, user_id, revision, '
      'operation_id, snapshot_json, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      ['w1', 'default', 501, 'operation-broken', '{not json', now],
    );
    current.rawExecute('DROP TABLE progress_operations');
    current.rawExecute('PRAGMA user_version = 26');
    current.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.tableExists('progress_operations'), isTrue);

    final remaining = migrated.listProgressRevisions('w1');
    expect(remaining.length, lessThan(40));
    expect(remaining.first.revision, 500);
    expect(remaining.map((revision) => revision.deviceId).toSet(), {
      'phone',
      'desktop',
    });
    // Recent pruned rows are remembered, ancient ones are not.
    final remembered = migrated
        .rawQuery('SELECT operation_id FROM progress_operations')
        .map((row) => row['operation_id'] as String)
        .toSet();
    expect(remembered, contains('operation-260'));
    expect(remembered, isNot(contains('operation-10')));
  });
}
