import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('a fresh database knows the opened vault as a source', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    final sources = database.listSources();
    expect(sources, hasLength(1));
    expect(sources.single.id, FundusDatabase.localSourceId);
    expect(sources.single.kind, LibrarySourceKind.vault);
    expect(database.columnExists('files', 'source_id'), isTrue);
    expect(database.columnExists('files', 'availability'), isTrue);
    expect(database.columnExists('files', 'offline_path'), isTrue);
    expect(database.columnExists('works', 'source_id'), isTrue);
    expect(database.columnExists('works', 'availability'), isTrue);
  });

  test('schema v7 is migrated to sourced files and works', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v7-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');

    final legacy = sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE files (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        filename TEXT NOT NULL,
        extension TEXT NOT NULL DEFAULT '',
        size INTEGER NOT NULL,
        file_modified_at INTEGER NOT NULL,
        indexed_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'available'
      )
    ''');
    legacy.execute('''
      CREATE TABLE works (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        source_path TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        added_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'available'
      )
    ''');
    legacy.execute(
      'INSERT INTO files (id, path, filename, size, file_modified_at, '
      "indexed_at, status) VALUES ('f1', 'Buch/01.m4b', '01.m4b', 12, 0, 0, "
      "'available')",
    );
    legacy.execute(
      'INSERT INTO files (id, path, filename, size, file_modified_at, '
      "indexed_at, status) VALUES ('f2', 'Buch/02.m4b', '02.m4b', 12, 0, 0, "
      "'missing')",
    );
    legacy.execute(
      "INSERT INTO works (id, kind, source_path, title, added_at, status) "
      "VALUES ('w1', 'audiobook', 'Buch', 'Ein Buch', 0, 'available')",
    );
    legacy.userVersion = 7;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);

    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.listSources().single.id, FundusDatabase.localSourceId);

    final files = migrated.rawQuery(
      'SELECT id, source_id, availability FROM files ORDER BY id',
    );
    expect(files, hasLength(2));
    expect(files.first['source_id'], FundusDatabase.localSourceId);
    expect(files.first['availability'], 'available');
    // A file the previous schema called missing is not lost, it is unreachable.
    expect(files.last['availability'], 'unreachable');

    final works = migrated.rawQuery(
      'SELECT source_id, availability FROM works',
    );
    expect(works.single['source_id'], FundusDatabase.localSourceId);
    expect(works.single['availability'], 'available');
  });

  test('the same path may exist once per source', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    database.upsertSource(
      const LibrarySource(
        id: 'peer-1',
        kind: LibrarySourceKind.peer,
        displayName: 'Nordspeicher',
        baseUrl: 'https://192.168.0.2:47891',
      ),
    );

    for (final source in [FundusDatabase.localSourceId, 'peer-1']) {
      database.rawExecute(
        'INSERT INTO files (id, source_id, path, filename, size, '
        'file_modified_at, indexed_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['file-$source', source, 'Buch/01.m4b', '01.m4b', 12, 0, 0],
      );
    }

    expect(database.rawQuery('SELECT id FROM files'), hasLength(2));
  });

  test('an unreachable peer changes origin but keeps its rows', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    database.upsertSource(
      const LibrarySource(
        id: 'peer-1',
        kind: LibrarySourceKind.peer,
        displayName: 'Fernarchiv',
      ),
    );
    database.rawExecute(
      "INSERT INTO works (id, source_id, kind, source_path, title, added_at, "
      "availability) VALUES ('w1', 'peer-1', 'audiobook', 'Buch', 'Titel', 0, "
      "'remote')",
    );

    database.setSourceReachable('peer-1', reachable: false);

    final rows = database.rawQuery(
      'SELECT title, availability FROM works WHERE id = ?',
      ['w1'],
    );
    expect(rows.single['title'], 'Titel');
    expect(rows.single['availability'], 'unreachable');
    expect(
      database.loadSource('peer-1')!.status,
      LibrarySourceStatus.unreachable,
    );
  });

  test('an offline copy survives its source going away', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    database.upsertSource(
      const LibrarySource(
        id: 'peer-1',
        kind: LibrarySourceKind.peer,
        displayName: 'Fernarchiv',
      ),
    );
    database.rawExecute(
      "INSERT INTO works (id, source_id, kind, source_path, title, added_at, "
      "availability) VALUES ('w1', 'peer-1', 'manga', 'Reihe', 'Titel', 0, "
      "'offline_copy')",
    );

    database.setSourceReachable('peer-1', reachable: false);

    final rows = database.rawQuery(
      'SELECT availability FROM works WHERE id = ?',
      ['w1'],
    );
    expect(rows.single['availability'], 'offline_copy');
  });
}
