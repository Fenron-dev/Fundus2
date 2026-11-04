import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Somebody moving from Plex has years of metadata and watched marks in its
/// database. Fundus takes them over, finding works by their files, without
/// overwriting what a person decided in Fundus.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-plex-');
  });

  tearDown(() => root.delete(recursive: true));

  /// The parts of a Plex database Fundus reads, in Plex's own shape.
  File plexDatabase() {
    final file = File('${root.path}/com.plexapp.plugins.library.db');
    final db = sqlite3.open(file.path);
    db.execute('''
      CREATE TABLE metadata_items (
        id INTEGER PRIMARY KEY, parent_id INTEGER, metadata_type INTEGER,
        guid TEXT, title TEXT, original_title TEXT, summary TEXT,
        year INTEGER, studio TEXT, "index" INTEGER, tags_genre TEXT,
        deleted_at INTEGER);
      CREATE TABLE media_items (id INTEGER PRIMARY KEY, metadata_item_id INTEGER);
      CREATE TABLE media_parts (id INTEGER PRIMARY KEY, media_item_id INTEGER,
        file TEXT, size INTEGER);
      CREATE TABLE tags (id INTEGER PRIMARY KEY, tag TEXT, tag_type INTEGER);
      CREATE TABLE taggings (id INTEGER PRIMARY KEY, metadata_item_id INTEGER,
        tag_id INTEGER);
      CREATE TABLE metadata_item_settings (id INTEGER PRIMARY KEY,
        account_id INTEGER, guid TEXT, view_count INTEGER, view_offset INTEGER,
        last_viewed_at INTEGER);

      INSERT INTO metadata_items VALUES
        (1, NULL, 1, 'plex://movie/abc', 'Nordwind', 'North Wind',
         'Ein Sturm zieht auf.', 2019, 'Nordfilm', NULL, 'Drama|Thriller', NULL),
        (10, NULL, 2, 'plex://show/def', 'Die Küste', NULL,
         'Eine Serie am Meer.', 2021, NULL, NULL, NULL, NULL),
        (11, 10, 3, 'plex://season/s1', 'Staffel 1', NULL, NULL, NULL, NULL,
         1, NULL, NULL),
        (12, 11, 4, 'plex://episode/e1', 'Ankunft', NULL, NULL, NULL, NULL,
         1, NULL, NULL),
        (13, 11, 4, 'plex://episode/e2', 'Abfahrt', NULL, NULL, NULL, NULL,
         2, NULL, NULL);
      INSERT INTO media_items VALUES (1, 1), (2, 12), (3, 13);
      INSERT INTO media_parts VALUES
        (1, 1, '/volume1/Filme/Nordwind/Nordwind.mkv', 3),
        (2, 2, 'D:\\Serien\\Die Kueste\\S01E01.mkv', 4),
        (3, 3, 'D:\\Serien\\Die Kueste\\S01E02.mkv', 5);
      INSERT INTO tags VALUES (1, 'imdb://tt1234567', 314), (2, 'Ada Regie', 4);
      INSERT INTO taggings VALUES (1, 1, 1), (2, 1, 2);
      INSERT INTO metadata_item_settings VALUES
        (1, 1, 'plex://movie/abc', 1, NULL, 1700000000),
        (2, 1, 'plex://episode/e1', 1, NULL, 1700000100),
        (3, 1, 'plex://episode/e2', 0, 600000, 1700000200),
        (4, 2, 'plex://episode/e2', 5, NULL, 1700000300);
    ''');
    db.close();
    return file;
  }

  test('the reader understands a Plex database it only copies', () async {
    final source = plexDatabase();
    final before = await source.readAsBytes();
    final items = await const PlexLibraryReader().read(source);
    expect(await source.readAsBytes(), before);

    final movie = items.firstWhere((item) => item.id == 1);
    expect(movie.type, PlexItem.movie);
    expect(movie.genres, containsAll(['Drama', 'Thriller']));
    expect(movie.directors, ['Ada Regie']);
    expect(movie.externalIds, {'imdb': 'tt1234567'});
    expect(movie.files.single, (filename: 'Nordwind.mkv', size: 3));
    expect(movie.watched, isTrue);
    // The account with the most history is the owner, not account 2.
    final second = items.firstWhere((item) => item.id == 13);
    expect(second.watched, isFalse);
    expect(second.viewOffset, const Duration(minutes: 10));
    expect(second.files.single.filename, 'S01E02.mkv');
  });

  test('a file that is not a Plex database is refused', () async {
    final file = File('${root.path}/fake.db')..writeAsStringSync('no');
    await expectLater(
      const PlexLibraryReader().read(file),
      throwsFormatException,
    );
  });

  test('Plex metadata and watch marks reach the matching works', () async {
    final film = Directory('${root.path}/Filme/Nordwind')
      ..createSync(recursive: true);
    File('${film.path}/Nordwind.mkv').writeAsBytesSync([1, 2, 3]);
    final show = Directory('${root.path}/Serien/Die Kueste')
      ..createSync(recursive: true);
    File('${show.path}/S01E01.mkv').writeAsBytesSync([1, 2, 3, 4]);
    File('${show.path}/S01E02.mkv').writeAsBytesSync([1, 2, 3, 4, 5]);
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final items = await const PlexLibraryReader().read(plexDatabase());

    final report = await library.importPlexLibrary(items);
    expect(report.matchedWorks, 2);
    expect(report.updatedWorks, 2);
    expect(report.conflicts, isEmpty);

    final movie = library.listWorks().firstWhere(
      (work) => work.title == 'Nordwind',
    );
    expect(movie.description, 'Ein Sturm zieht auf.');
    expect(movie.publishedYear, 2019);
    expect(movie.genres, containsAll(['Drama', 'Thriller']));
    expect(movie.alternateTitles, contains('North Wind'));
    expect(
      movie.metadataOrigins['description']?.source,
      WorkMetadataSource.plex,
    );
    expect(library.finishedFiles(movie.id), hasLength(1));

    final series = library.listWorks().firstWhere(
      (work) => work.title == 'Die Küste',
    );
    expect(series.description, 'Eine Serie am Meer.');
    final tracks = library.playbackTracks(series.id);
    expect(library.finishedFiles(series.id), {tracks.first.fileId});
    final progress = library.loadProgress(series.id)!;
    expect(progress.fileId, tracks.last.fileId);
    expect(progress.position.numericValue, 600);
    expect(progress.deviceName, 'Plex');
  });

  test('what somebody decided in Fundus comes back as a conflict', () async {
    final film = Directory('${root.path}/Filme/Nordwind')
      ..createSync(recursive: true);
    File('${film.path}/Nordwind.mkv').writeAsBytesSync([1, 2, 3]);
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    await library.updateWorkMetadata(
      workId: work.id,
      title: work.title,
      authors: work.authors,
      subtitle: work.subtitle,
      series: work.series,
      seriesSequence: work.seriesSequence,
      narrators: work.narrators,
      language: work.language,
      description: 'Meine eigene Beschreibung.',
      publisher: work.publisher,
      publishedYear: work.publishedYear,
    );
    library.saveProgress(
      workId: work.id,
      fileId: library.playbackTracks(work.id).single.fileId,
      position: const Duration(minutes: 1),
      deviceId: 'mac',
    );
    final items = await const PlexLibraryReader().read(plexDatabase());

    final report = await library.importPlexLibrary(items);
    final updated = library.listWorks().single;
    expect(updated.description, 'Meine eigene Beschreibung.');
    expect(
      report.conflicts.single.fields.map((field) => field.field),
      contains('description'),
    );
    // Other fields still arrive.
    expect(updated.publishedYear, 2019);
    // And the position Fundus already had stays.
    expect(library.loadProgress(work.id)!.position.numericValue, 60);
  });
}
