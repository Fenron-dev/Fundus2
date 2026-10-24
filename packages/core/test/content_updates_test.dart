import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  group('portable content update state', () {
    ContentUpdateFile file(
      String key, {
      String revision = '1',
      String id = 'id',
    }) => ContentUpdateFile(
      workId: 'work',
      key: key,
      fileId: id,
      title: '$key.cbz',
      revision: revision,
    );

    test(
      'baseline is silent; adds, changes and removal are distinct and idempotent',
      () {
        final state = ContentUpdates()
          ..subscribe('work', [file('one'), file('two')]);
        expect(state.events, isEmpty);
        expect(state.reconcile([file('one'), file('two')]), isFalse);
        state.reconcile([file('one', revision: '2'), file('three')]);
        expect(
          state.events.map((event) => event.kind).toSet(),
          ContentUpdateKind.values.toSet(),
        );
        final ids = state.events.map((event) => event.id).toList();
        expect(
          state.reconcile([file('one', revision: '2'), file('three')]),
          isFalse,
        );
        expect(state.events.map((event) => event.id), ids);
        final copy = ContentUpdates.fromJson(
          jsonDecode(jsonEncode(state.toJson())),
        );
        expect(
          copy.reconcile([file('one', revision: '2'), file('three')]),
          isFalse,
        );
        copy.setDisposition(ids.first, ContentUpdateDisposition.later);
        expect(copy.events.first.disposition, ContentUpdateDisposition.later);
      },
    );

    test(
      'a changed index ID is not new content; repeated subscribe does not reset baseline',
      () {
        final state = ContentUpdates()..subscribe('work', [file('one')]);
        state.subscribe('work', [file('one'), file('two')]);
        expect(
          state.reconcile([file('one', id: 'rebuilt'), file('two')]),
          isTrue,
        );
        expect(state.events.single.file.key, 'two');
        state.unsubscribe('work');
        expect(state.reconcile([]), isFalse);
        state.subscribe('work', [file('one'), file('two')]);
        expect(state.reconcile([file('one'), file('two')]), isFalse);
      },
    );

    test(
      'unknown versions and malformed states are not interpreted as an empty inbox',
      () {
        expect(
          () => ContentUpdates.fromJson({'format_version': 2}),
          throwsFormatException,
        );
        final raw = ContentUpdates().toJson()..['sequence'] = -1;
        expect(() => ContentUpdates.fromJson(raw), throwsFormatException);
      },
    );
  });

  group('vault scan and catalogue integration', () {
    late Directory root;
    late Directory workFolder;
    late FundusLibrary library;
    late String id;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-updates-');
      workFolder = Directory('${root.path}/Manga/Series')
        ..createSync(recursive: true);
      File('${workFolder.path}/01.cbz').writeAsBytesSync([1, 2, 3]);
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      id = library.listWorks().single.id;
    });
    tearDown(() async {
      await library.shutdown();
      await root.delete(recursive: true);
    });

    test(
      'subscription starts silently, survives restart and notices a new part only once',
      () async {
        await library.setContentSubscription(id, true);
        expect(library.contentUpdates, isEmpty);
        await library.shutdown();
        library = await FundusLibrary.open(root);
        expect(library.contentSubscriptions, {id});
        File('${workFolder.path}/02.cbz').writeAsBytesSync([4, 5, 6]);
        await library.index().drain<void>();
        expect(library.contentUpdates.single.kind, ContentUpdateKind.added);
        final event = library.contentUpdates.single;
        await library.setContentUpdateDisposition(
          event.id,
          ContentUpdateDisposition.hidden,
        );
        await library.index(full: true).drain<void>();
        expect(library.contentUpdates, hasLength(1));
        expect(
          library.contentUpdates.single.disposition,
          ContentUpdateDisposition.hidden,
        );
        expect(library.loadProgress(id), isNull);
        await library.shutdown();
        library = await FundusLibrary.open(root);
        expect(library.contentUpdates.single.id, event.id);
        expect(
          library.contentUpdates.single.disposition,
          ContentUpdateDisposition.hidden,
        );
      },
    );

    test(
      'rebuilding only the index preserves the baseline and resolves existing events to new file IDs',
      () async {
        await library.setContentSubscription(id, true);
        File('${workFolder.path}/02.cbz').writeAsBytesSync([4, 5, 6]);
        await library.index().drain<void>();
        final event = library.contentUpdates.single;
        await library.shutdown();
        await File('${root.path}/.library/index.db').delete();
        library = await FundusLibrary.open(root);
        await library.index().drain<void>();
        expect(library.contentUpdates, hasLength(1));
        expect(library.listWorks().single.id, id);
        expect(
          library.resolveContentUpdateFile(event),
          library.playbackTracks(id).last.fileId,
        );
      },
    );

    test(
      'changed files and removed files do not count as new chapters',
      () async {
        await library.setContentSubscription(id, true);
        File('${workFolder.path}/01.cbz').writeAsBytesSync([7, 8, 9, 10]);
        await library.index().drain<void>();
        expect(library.contentUpdates.single.kind, ContentUpdateKind.changed);
        await File('${workFolder.path}/01.cbz').delete();
        await library.index().drain<void>();
        expect(library.contentUpdates.first.kind, ContentUpdateKind.removed);
        expect(
          library.contentUpdates.where(
            (event) => event.kind == ContentUpdateKind.added,
          ),
          isEmpty,
        );
      },
    );

    test(
      'peer revisions survive delta import without timestamp-induced phantom changes',
      () async {
        library.registerPeerSource(
          sourceId: 'peer-test',
          displayName: 'Test',
          libraryId: 'remote',
          baseUrl: 'https://localhost',
        );
        RemoteWorkRecord remote({
          String revision = 'v1',
          bool second = false,
        }) => RemoteWorkRecord(
          id: 'remote-work',
          kind: 'webnovel',
          title: 'Remote',
          files: [
            RemoteFileRecord(
              id: 'file-one',
              filename: '01.epub',
              position: 0,
              sizeBytes: 50,
              contentRevision: revision,
            ),
            if (second)
              const RemoteFileRecord(
                id: 'file-two',
                filename: '02.epub',
                position: 1,
                sizeBytes: 40,
              ),
          ],
        );
        library.mirrorRemoteCatalogue(sourceId: 'peer-test', works: [remote()]);
        await library.setContentSubscription('remote-work', true);
        library.mirrorRemoteCatalogue(sourceId: 'peer-test', works: [remote()]);
        await library.flushSidecarWrites();
        expect(library.contentUpdates, isEmpty);
        library.mirrorRemoteCatalogue(
          sourceId: 'peer-test',
          works: [remote(revision: 'v2', second: true)],
        );
        await library.flushSidecarWrites();
        expect(library.contentUpdates.map((event) => event.kind).toSet(), {
          ContentUpdateKind.added,
          ContentUpdateKind.changed,
        });
        expect(library.playbackTracks('remote-work').first.sizeBytes, 50);
        expect(
          library.playbackTracks('remote-work').first.contentRevision,
          'v2',
        );
      },
    );

    test(
      'a future inbox is preserved and cannot be overwritten by the current app',
      () async {
        final file = File('${root.path}/_fundus/content-updates.json');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{"format_version":99,"future":"data"}');
        await library.shutdown();
        library = await FundusLibrary.open(root);
        expect(library.contentUpdatesError, isNotNull);
        await expectLater(
          library.setContentSubscription(id, true),
          throwsA(anything),
        );
        await library.index().drain<void>();
        expect(file.readAsStringSync(), contains('"future":"data"'));
      },
    );
  });
}
