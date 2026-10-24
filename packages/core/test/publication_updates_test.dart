import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

import 'epub_package_test.dart' show epubFixture;

void main() {
  group('publication manifest contract', () {
    test(
      'rejects future formats, duplicate IDs, excessive units and false unsupported bodies',
      () {
        final unit = PublicationUnit(
          id: 'one',
          title: 'One',
          revision: 'a' * 64,
        ).toJson();
        Map<String, Object?> raw() => {
          'format_version': 1,
          'file_revision': 'v1',
          'units': [unit],
        };
        expect(
          () => PublicationManifest.fromJson(raw()..['format_version'] = 2),
          throwsFormatException,
        );
        expect(
          () => PublicationManifest.fromJson(raw()..['units'] = [unit, unit]),
          throwsFormatException,
        );
        expect(
          () => PublicationManifest.fromJson(
            raw()..['units'] = List.filled(10001, unit),
          ),
          throwsFormatException,
        );
        expect(
          () => PublicationManifest.fromJson(raw()..['supported'] = false),
          throwsFormatException,
        );
        expect(
          () => PublicationManifest.fromJson(raw()..['supported'] = 'true'),
          throwsFormatException,
        );
      },
    );

    test('v1 inbox acquires a silent chapter baseline and upgrades to v2', () {
      const before = ContentUpdateFile(
        workId: 'w',
        key: 'f',
        fileId: 'f',
        title: 'Novel',
        revision: 'v1',
      );
      final legacy = ContentUpdates()..subscribe('w', [before]);
      final raw = legacy.toJson()..['format_version'] = 1;
      final state = ContentUpdates.fromJson(jsonDecode(jsonEncode(raw)));
      final unit = PublicationUnit(id: 'one', title: 'One', revision: 'a' * 64);
      state.reconcile([
        ContentUpdateFile(
          workId: 'w',
          key: 'f',
          fileId: 'f',
          title: 'Novel',
          revision: 'v1',
          units: [unit],
        ),
      ]);
      expect(state.events, isEmpty);
      expect(state.toJson()['format_version'], 2);
      final reopened = ContentUpdates.fromJson(state.toJson());
      reopened.reconcile([
        ContentUpdateFile(
          workId: 'w',
          key: 'f',
          fileId: 'f',
          title: 'Novel',
          revision: 'v2',
          units: [
            unit,
            PublicationUnit(id: 'two', title: 'Two', revision: 'b' * 64),
          ],
        ),
      ]);
      expect(reopened.events.single.kind, ContentUpdateKind.added);
      expect(reopened.events.single.file.chapterId, 'two');
    });

    test(
      'retention bounds handled history without losing unread or later notices',
      () {
        final state = ContentUpdates()..subscribe('w', []);
        state.reconcile([
          for (var i = 0; i < 1005; i++)
            ContentUpdateFile(
              workId: 'w',
              key: '$i',
              fileId: '$i',
              title: '$i',
              revision: '1',
            ),
        ]);
        final ids = state.events.map((event) => event.id).toList();
        state.setDisposition(ids.last, ContentUpdateDisposition.later);
        for (final id in ids.take(600)) {
          state.setDisposition(id, ContentUpdateDisposition.seen);
        }
        expect(
          state.events.where(
            (event) => event.disposition == ContentUpdateDisposition.seen,
          ),
          hasLength(500),
        );
        expect(
          state.events.where(
            (event) => event.disposition == ContentUpdateDisposition.unread,
          ),
          hasLength(404),
        );
        expect(
          state.events.where(
            (event) => event.disposition == ContentUpdateDisposition.later,
          ),
          hasLength(1),
        );
      },
    );

    test('transiently deferred works keep their previous chapter baseline', () {
      const file = ContentUpdateFile(
        workId: 'w',
        key: 'f',
        fileId: 'f',
        title: 'File',
        revision: '1',
      );
      final state = ContentUpdates()..subscribe('w', [file]);
      expect(state.reconcile([], deferredWorkIds: {'w'}), isFalse);
      expect(state.events, isEmpty);
      expect(state.reconcile([file]), isFalse);
    });
  });

  group('indexed EPUB chapter updates', () {
    late Directory root;
    late File book;
    late FundusLibrary library;
    late String id;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-chapter-updates-');
      book = File('${root.path}/Webnovels/Series/Novel.epub');
      await book.parent.create(recursive: true);
      await book.writeAsBytes(epubFixture(includeSecond: false));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      id = library.listWorks().single.id;
    });
    tearDown(() async {
      await library.shutdown();
      await root.delete(recursive: true);
    });

    test(
      'new and changed embedded chapters are separate notices, not a whole-file guess',
      () async {
        await library.setContentSubscription(id, true);
        final fileId = library.playbackTracks(id).single.fileId;
        expect(library.cachedPublicationManifest(fileId)!.units, hasLength(1));
        await book.writeAsBytes(
          epubFixture(firstBody: 'Dieser Absatz wurde geändert.'),
        );
        await library.index().drain<void>();
        expect(library.contentUpdates, hasLength(2));
        expect(library.contentUpdates.map((event) => event.kind).toSet(), {
          ContentUpdateKind.added,
          ContentUpdateKind.changed,
        });
        expect(
          library.contentUpdates.every((event) => event.file.chapterId != null),
          isTrue,
        );
        final added = library.contentUpdates.singleWhere(
          (event) => event.kind == ContentUpdateKind.added,
        );
        expect(added.file.title, contains('Unterkapitel Zwei'));
        expect(library.resolveContentUpdateFile(added), fileId);
        final inbox = File('${root.path}/_fundus/content-updates.json');
        final oldTime = DateTime.utc(2000);
        await inbox.setLastModified(oldTime);
        await library.index().drain<void>();
        expect(library.contentUpdates, hasLength(2));
        expect((await inbox.stat()).modified.toUtc(), oldTime);
        expect(library.loadProgress(id), isNull);
      },
    );

    test(
      'chapter deletion is not a new chapter and a rebuilt index retains history',
      () async {
        await book.writeAsBytes(epubFixture());
        await library.index().drain<void>();
        await library.setContentSubscription(id, true);
        await book.writeAsBytes(epubFixture(includeSecond: false));
        await library.index().drain<void>();
        expect(library.contentUpdates.single.kind, ContentUpdateKind.removed);
        final eventId = library.contentUpdates.single.id;
        await library.shutdown();
        await File('${root.path}/.library/index.db').delete();
        library = await FundusLibrary.open(root);
        await library.index().drain<void>();
        expect(library.contentUpdates, hasLength(1));
        expect(library.contentUpdates.single.id, eventId);
      },
    );

    test(
      'concurrent chapter requests share one task and shutdown waits for it',
      () async {
        final fileId = library.playbackTracks(id).single.fileId;
        final first = library.ensurePublicationManifest(fileId);
        final second = library.ensurePublicationManifest(fileId);
        expect(identical(first, second), isTrue);
        await library.shutdown();
        expect((await first)!.units, hasLength(1));
        library = await FundusLibrary.open(root);
        expect(library.cachedPublicationManifest(fileId)!.units, hasLength(1));
      },
    );

    test(
      'an unindexed changed file cannot be hashed under the old revision',
      () async {
        final fileId = library.playbackTracks(id).single.fileId;
        await book.writeAsBytes(epubFixture());
        await expectLater(
          library.ensurePublicationManifest(fileId),
          throwsA(isA<FileSystemException>()),
        );
        expect(library.cachedPublicationManifest(fileId), isNull);
        await library.index().drain<void>();
        expect(
          (await library.ensurePublicationManifest(fileId))!.units,
          hasLength(2),
        );
      },
    );

    test(
      'subtree and cancelled scans do not invent removed/new chapters outside the scope',
      () async {
        final other = File('${root.path}/Webnovels/Other/Other.epub');
        await other.parent.create(recursive: true);
        await other.writeAsBytes(epubFixture());
        await library.index().drain<void>();
        await library.subscribeContentWorks(
          library.listWorks().map((work) => work.id).toSet(),
        );
        await other.delete();
        await book.writeAsBytes(epubFixture());
        final cancelled = ScanCancellationToken()..cancel();
        await library.index(cancellationToken: cancelled).drain<void>();
        expect(library.contentUpdates, isEmpty);
        await library.index(subtree: 'Webnovels/Series').drain<void>();
        expect(library.contentUpdates.single.kind, ContentUpdateKind.added);
        expect(library.contentUpdates.single.file.workId, id);
      },
    );

    test(
      'schema 23 upgrades to 24 without deleting media or progress',
      () async {
        final fileId = library.playbackTracks(id).single.fileId;
        library.saveMediaProgress(
          workId: id,
          fileId: fileId,
          position: MediaPosition(
            kind: MediaPositionKind.epubCfi,
            fileId: fileId,
            numericValue: .3,
          ),
        );
        await library.shutdown();
        final db = FundusDatabase.openFile(
          File('${root.path}/.library/index.db'),
        );
        db.rawExecute(
          'ALTER TABLE files DROP COLUMN publication_manifest_json',
        );
        db.rawExecute('PRAGMA user_version = 23');
        db.rawExecute('DROP TABLE metadata_history_batches');
        db.rawExecute('DROP TABLE metadata_history_state');
        db.close();
        library = await FundusLibrary.open(root);
        final probe = FundusDatabase.openFile(
          File('${root.path}/.library/index.db'),
        );
        expect(probe.userVersion, FundusDatabase.schemaVersion);
        expect(
          probe.columnExists('files', 'publication_manifest_json'),
          isTrue,
        );
        probe.close();
        expect(library.loadProgress(id)!.position.numericValue, .3);
        expect(await book.exists(), isTrue);
      },
    );
  });
}
