import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/download_controller.dart';
import 'package:fundus/data/offline_controller.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Taking a work with you.
///
/// Streaming stops at the front door — a train, a cellar. What is tried here
/// is that a downloaded work stops being a network question at all: the files
/// are here, the players open them without knowing anything changed, and
/// deleting the copy puts the work back on the network.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraries peers;
  late DownloadController downloads;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-download-');
    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    for (final name in ['01 - Anfang.mp3', '02 - Mitte.mp3']) {
      await File('${work.path}/$name').writeAsBytes(List.filled(1024, 3));
    }
    theirs = await FundusLibrary.create(source);
    await for (final _ in theirs.index()) {}

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        serverName: 'Mac',
        registry: registry,
      ).handler,
      'localhost',
      0,
    );

    library = LibraryController();
    settings = AppSettings.inMemory();
    peers = PeerLibraries(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/speicher'),
    );
    downloads = DownloadController(
      library: library,
      storageRoot: () async => Directory('${temporary.path}/speicher'),
    );

    await peers.connect(
      PeerConnection(
        serverId: 'server-test',
        name: 'Mac',
        baseUrl: 'http://localhost:${socket.port}',
        token: 'geheim',
      ),
    );
    // Der Download fragt pro Quelle, weil ein Vault mehrere Geräte trägt.
    downloads.proxyForSource = (sourceId) => peers.forSource(sourceId)?.proxy;
  });

  tearDown(() async {
    downloads.dispose();
    peers.dispose();
    library.dispose();
    await socket.close(force: true);
    registry.close();
    await temporary.delete(recursive: true);
  });

  WorkView theWork() => library.works.single;

  Future<void> settle() async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (downloads.jobFor(theWork().id)?.state == DownloadState.done) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail(
      'Der Download ist nicht fertig geworden: '
      '${downloads.jobFor(theWork().id)?.failure}',
    );
  }

  Future<OfflineController> smart({
    bool wifi = true,
    int next = 1,
    int budget = 1048576,
    bool cleanup = false,
  }) async {
    await settings.setOfflineConfiguration(
      library.library!.manifest.libraryId,
      OfflinePolicy(
        enabled: true,
        nextFiles: next,
        storageBudgetBytes: budget,
        removeConsumed: cleanup,
      ),
      [
        OfflineRule(
          scope: OfflineRuleScope.work,
          targetId: theWork().id,
          nextFiles: next,
        ),
      ],
    );
    final controller = OfflineController(
      settings: settings,
      library: library,
      downloads: downloads,
      conditions: () async => OfflineConditions(wifi: wifi, charging: true),
      scheduleAutomatically: false,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<
    ({
      OfflineController offline,
      SyncController sync,
      String first,
      String last,
      String path,
    })
  >
  cleanupScenario() async {
    final offline = await smart(cleanup: true);
    await downloads.download(theWork());
    await settle();
    final vault = library.library!;
    final files = vault.contentFiles(theWork().id);
    vault.setFileFinished(
      workId: theWork().id,
      fileId: files.first.fileId,
      finished: true,
    );
    vault.saveProgress(
      workId: theWork().id,
      fileId: files.last.fileId,
      position: const Duration(seconds: 30),
      deviceId: settings.deviceKey,
      checkpoint: true,
    );
    await settings.savePeer(
      PeerConnection(
        serverId: 'server-test',
        name: 'Mac',
        baseUrl: 'http://localhost:${socket.port}',
        token: 'geheim',
        libraryId: theirs.manifest.libraryId,
      ),
    );
    final sync = SyncController(settings: settings, library: library);
    addTearDown(sync.dispose);
    return (
      offline: offline,
      sync: sync,
      first: files.first.fileId,
      last: files.last.fileId,
      path: files.first.offlinePath!,
    );
  }

  test(
    'consumed copy is retained until its own checkpoint has a durable server receipt',
    () async {
      final scenario = await cleanupScenario();
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
      final before = OfflineCheckpointReceipt.fingerprintOf(
        library.library!.loadProgress(theWork().id)!,
      );
      final report = await scenario.sync.syncWith(settings.peers.single);
      expect(report!.failures, isEmpty);
      expect(settings.offlineCheckpointReceipts, hasLength(1));
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isFalse);
      expect(downloads.offlineFileCount(theWork().id), 1);
      expect(
        OfflineCheckpointReceipt.fingerprintOf(
          library.library!.loadProgress(theWork().id)!,
        ),
        before,
      );
      expect(
        await File(
          theirs.playbackTracks(theWork().id).first.absolutePath,
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'a newer local checkpoint invalidates a previous cleanup receipt',
    () async {
      final scenario = await cleanupScenario();
      await scenario.sync.syncWith(settings.peers.single);
      library.library!.saveProgress(
        workId: theWork().id,
        fileId: scenario.last,
        position: const Duration(seconds: 45),
        deviceId: settings.deviceKey,
        checkpoint: true,
      );
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
    },
  );

  test('removal permission is rechecked after filesystem validation', () async {
    final scenario = await cleanupScenario();
    var checks = 0;
    final removed = await downloads.removeFiles(
      theWork().id,
      only: {scenario.first},
      verifyRevision: true,
      mayRemove: (_) => ++checks == 1,
    );
    expect(checks, 2);
    expect(removed, 0);
    expect(await File(scenario.path).exists(), isTrue);
    expect(downloads.offlineFileCount(theWork().id), 2);
  });

  test(
    'active, hidden and backgrounded works are not automatically cleaned',
    () async {
      final scenario = await cleanupScenario();
      await scenario.sync.syncWith(settings.peers.single);
      final id = theWork().id;
      scenario.offline.inUseWorkIds = () => {id};
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
      scenario.offline.inUseWorkIds = () => {};
      library.hides = (_) => true;
      library.refresh();
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
      library.hides = null;
      library.refresh();
      scenario.offline.setForeground(false);
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
    },
  );

  test(
    'an unresolved position choice or stale media revision keeps the copy',
    () async {
      final scenario = await cleanupScenario();
      await scenario.sync.syncWith(settings.peers.single);
      final vault = library.library!;
      vault.recordProgressChoice(
        LibraryProgressChoice(
          workId: theWork().id,
          position: MediaPosition(
            kind: MediaPositionKind.time,
            numericValue: 10,
            fileId: scenario.last,
          ),
          fileId: scenario.last,
          finished: false,
          deviceId: 'other',
          deviceName: 'Other',
          updatedAt: DateTime.now(),
          recordedAt: DateTime.now(),
        ),
      );
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
      vault.clearProgressChoice(theWork().id);
      final marker = File('${scenario.path}.meta');
      final value =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      value['revision'] = 'outdated';
      await marker.writeAsString(jsonEncode(value));
      await scenario.offline.run(force: true);
      expect(await File(scenario.path).exists(), isTrue);
    },
  );

  test(
    'neither manual nor automatic removal deletes an original outside the managed cache',
    () async {
      final scenario = await cleanupScenario();
      await scenario.sync.syncWith(settings.peers.single);
      final original = File('${temporary.path}/original.mp3');
      await original.writeAsBytes([9, 8, 7]);
      library.library!.setOfflineCopy(
        fileId: scenario.first,
        path: original.path,
      );
      await scenario.offline.run(force: true);
      expect(await original.readAsBytes(), [9, 8, 7]);
      await downloads.remove(theWork().id);
      expect(await original.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'a symlinked cache directory cannot authorize deleting a linked original',
    () async {
      final scenario = await cleanupScenario();
      await scenario.sync.syncWith(settings.peers.single);
      final folder = File(scenario.path).parent;
      await folder.rename('${folder.path}-held');
      final originals = Directory('${temporary.path}/originals');
      await originals.create();
      final original = File(
        '${originals.path}/${File(scenario.path).uri.pathSegments.last}',
      );
      await original.writeAsBytes([9, 8, 7]);
      await Link(folder.path).create(originals.path);
      await scenario.offline.run(force: true);
      expect(await original.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'offline rules are installation-local, versioned and separated by vault',
    () async {
      const first = OfflineRule(
        scope: OfflineRuleScope.work,
        targetId: 'work-a',
        nextFiles: 5,
      );
      await settings.setOfflineRules('vault-a', [first, first]);
      await settings.setOfflineRules('vault-b', [
        const OfflineRule(scope: OfflineRuleScope.shelf, targetId: 'shelf-b'),
      ]);
      expect(settings.offlineRules('vault-a').single.nextFiles, 5);
      expect(
        settings.offlineRules('vault-b').single.scope,
        OfflineRuleScope.shelf,
      );
      final future = AppSettings.inMemory(
        values: {
          'offline_rules': {'format_version': 2, 'libraries': {}},
        },
      );
      expect(
        () => future.setOfflineRules('vault-a', []),
        throwsFormatException,
      );
      final futurePolicy = AppSettings.inMemory(
        values: {
          'offline_policy': {'format_version': 2},
        },
      );
      await expectLater(
        futurePolicy.setOfflineConfiguration(
          'vault-a',
          const OfflinePolicy(),
          [],
        ),
        throwsFormatException,
      );
      expect(OfflineRule.fromJson(first.toJson()).key, first.key);
      expect(
        () => OfflineRule.fromJson(first.toJson()..['next_files'] = 0),
        throwsFormatException,
      );
    },
  );

  test(
    'smart preview expands a saved shelf, with a specific work rule taking precedence',
    () async {
      final controller = await smart();
      final views = await library.library!.saveView(
        'Hörregal',
        const LibraryWorkQuery(kinds: {'audiobook'}),
      );
      await settings.setOfflineRules(library.library!.manifest.libraryId, [
        OfflineRule(
          scope: OfflineRuleScope.shelf,
          targetId: views.single.id,
          nextFiles: 2,
        ),
        OfflineRule(
          scope: OfflineRuleScope.work,
          targetId: theWork().id,
          nextFiles: 1,
        ),
      ]);
      final plan = await controller.preview();
      expect(plan.files, hasLength(1));
      expect(plan.bytesToDownload, 1024);
      expect(downloads.jobs, isEmpty);
      expect(library.library!.loadProgress(theWork().id), isNull);
    },
  );

  test('smart downloads respect wifi and foreground gates', () async {
    final controller = await smart(wifi: false);
    final plan = await controller.preview();
    expect(plan.files, isEmpty);
    expect(plan.deferred[theWork().id], OfflineDeferral.wifiRequired);
    await controller.run(force: true);
    expect(downloads.jobs, isEmpty);
    controller.setForeground(false);
    expect(
      (await controller.preview()).deferred[theWork().id],
      OfflineDeferral.background,
    );
    await controller.run(force: true);
    expect(downloads.jobs, isEmpty);
  });

  test('offline budget includes copies from hidden or other vaults', () async {
    final controller = await smart(budget: 4096);
    final other = File(
      '${temporary.path}/speicher/offline/other-vault/private.mp4',
    );
    await other.parent.create(recursive: true);
    await other.writeAsBytes(List.filled(4096, 1));
    final plan = await controller.preview();
    expect(plan.files, isEmpty);
    expect(plan.deferred[theWork().id], OfflineDeferral.budgetExceeded);
  });

  test(
    'smart selection downloads once and does not keep refilling the next N',
    () async {
      final controller = await smart();
      await controller.run(force: true);
      await settle();
      expect(downloads.offlineFileCount(theWork().id), 1);
      expect((await controller.preview()).files, isEmpty);
      await controller.run(force: true);
      expect(downloads.offlineFileCount(theWork().id), 1);
    },
  );

  test(
    'enabled rule changes automatically start the existing queue in foreground',
    () async {
      final controller = OfflineController(
        settings: settings,
        library: library,
        downloads: downloads,
        conditions: () async =>
            const OfflineConditions(wifi: true, charging: true),
      );
      addTearDown(controller.dispose);
      await settings.setOfflineConfiguration(
        library.library!.manifest.libraryId,
        const OfflinePolicy(enabled: true),
        [
          OfflineRule(
            scope: OfflineRuleScope.work,
            targetId: theWork().id,
            nextFiles: 1,
          ),
        ],
      );
      await settle();
      expect(downloads.offlineFileCount(theWork().id), 1);
    },
  );

  test('hidden works produce no smart preview or jobs', () async {
    final controller = await smart();
    library.hides = (_) => true;
    library.refresh();
    final plan = await controller.preview();
    expect(plan.files, isEmpty);
    expect(plan.deferred, isEmpty);
    await controller.run(force: true);
    expect(downloads.jobs, isEmpty);
  });

  test(
    'an externally deleted offline copy is selected and fetched again',
    () async {
      final controller = await smart();
      final first = library.library!.contentFiles(theWork().id).first.fileId;
      await downloads.download(theWork(), only: {first});
      await settle();
      final copy = library.library!
          .contentFiles(theWork().id)
          .firstWhere((file) => file.fileId == first)
          .offlinePath!;
      await File(copy).delete();
      final plan = await controller.preview();
      expect(plan.files.single.track.fileId, first);
      expect(plan.files.single.track.isRemote, isTrue);
      await controller.run(force: true);
      await settle();
      expect(await File(copy).exists(), isTrue);
    },
  );

  test('paused retry preserves both selection and transfer guard', () async {
    final file = library.library!.contentFiles(theWork().id).first;
    var allowed = false;
    await downloads.download(
      theWork(),
      only: {file.fileId},
      mayTransfer: () async => allowed,
    );
    Future<void> paused() async {
      for (
        var i = 0;
        i < 200 &&
            downloads.jobFor(theWork().id)?.state != DownloadState.paused;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(downloads.jobFor(theWork().id)?.state, DownloadState.paused);
    }

    await paused();
    await downloads.retry(theWork());
    await paused();
    expect(downloads.offlineFileCount(theWork().id), 0);
    allowed = true;
    await downloads.retry(theWork());
    await settle();
    expect(downloads.offlineFileCount(theWork().id), 1);
    expect(downloads.jobFor(theWork().id)!.total, 1);
  });

  test(
    'a finished partial job can fetch a later explicitly chosen file',
    () async {
      final files = library.library!.contentFiles(theWork().id);
      await downloads.download(theWork(), only: {files.first.fileId});
      await settle();
      await downloads.download(theWork(), only: {files.last.fileId});
      await settle();
      expect(downloads.isSecured(theWork().id), isTrue);
    },
  );

  test('ein gestreamtes Werk lässt sich mitnehmen', () async {
    expect(theWork().origin, FundusOrigin.stream);
    expect(downloads.canDownload(theWork()), isTrue);

    await downloads.download(theWork());
    await settle();

    expect(downloads.isSecured(theWork().id), isTrue);
    // Und es ist jetzt offline gesichert, nicht mehr ein Stream.
    expect(theWork().origin, FundusOrigin.offline);
  });

  test('danach öffnen die Spieler eine Datei, kein Netz', () async {
    await downloads.download(theWork());
    await settle();

    final tracks = library.library!.playbackTracks(theWork().id);
    expect(tracks, hasLength(2));
    for (final track in tracks) {
      expect(track.isRemote, isFalse);
      expect(await File(track.absolutePath).length(), 1024);
    }
  });

  test('halb heruntergeladen ist nicht offline', () async {
    final files = library.library!.contentFiles(theWork().id);
    library.library!.setOfflineCopy(
      fileId: files.first.fileId,
      path: '${temporary.path}/eine.mp3',
    );
    library.refresh();

    // Eine von zwei Dateien: das Werk darf nicht behaupten, es sei fertig.
    expect(downloads.isSecured(theWork().id), isFalse);
    expect(theWork().origin, isNot(FundusOrigin.offline));
  });

  test('entfernen gibt das Werk ans Netz zurück', () async {
    await downloads.download(theWork());
    await settle();
    final copies = library.library!
        .contentFiles(theWork().id)
        .map((file) => file.offlinePath!)
        .toList();

    await downloads.remove(theWork().id);

    expect(downloads.isSecured(theWork().id), isFalse);
    expect(theWork().origin, FundusOrigin.stream);
    for (final path in copies) {
      expect(await File(path).exists(), isFalse);
    }
    // Und die Spuren zeigen wieder auf die Gegenstelle.
    expect(
      library.library!.playbackTracks(theWork().id).first.isRemote,
      isTrue,
    );
  });

  test('der belegte Platz wird nach Medienart aufgeteilt', () async {
    await downloads.download(theWork());
    await settle();
    await downloads.measureStorage();

    // Zwei Dateien à 1024 Byte.
    expect(downloads.storedBytes, 2048);
    expect(downloads.storageByType, hasLength(1));

    // Und was gelöscht ist, zählt nicht mehr mit.
    await downloads.remove(theWork().id);
    await downloads.measureStorage();
    expect(downloads.storedBytes, 0);
  });

  test('nur die gewählten Dateien kommen mit', () async {
    final files = library.library!.contentFiles(theWork().id);
    expect(files, hasLength(2));

    await downloads.download(theWork(), only: {files.first.fileId});
    await settle();

    // Eine ist da, die andere nicht — und damit gilt das Werk nicht als
    // vollständig gesichert.
    final after = library.library!.contentFiles(theWork().id);
    expect(
      after.where((file) => file.availability == 'offline_copy'),
      hasLength(1),
    );
    expect(downloads.isSecured(theWork().id), isFalse);
  });

  test('Fortschritt zählt Bytes statt nur Dateien', () {
    const job = DownloadJob(
      workId: 'film',
      title: 'Film',
      state: DownloadState.running,
      done: 0,
      total: 2,
      bytesDone: 0,
      bytesTotal: 1010,
      currentBytes: 1000,
      fraction: .5,
    );

    // Die halbe große Datei sind fast 50 %, nicht 25 % (Datei 1 von 2).
    expect(job.progress, closeTo(500 / 1010, .0001));
  });

  test('ein laufender Auftrag lässt sich zurücknehmen', () async {
    // Vorher nicht: `cancel` gab bei einem laufenden Auftrag auf. Ein großer
    // Film blockierte damit unkündbar die einzige Spur, über die alles andere
    // geholt wird.
    unawaited(downloads.download(theWork()));
    for (var attempt = 0; attempt < 200; attempt++) {
      if (downloads.jobFor(theWork().id) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(downloads.jobFor(theWork().id), isNotNull);

    downloads.cancel(theWork().id);
    expect(downloads.jobFor(theWork().id), isNull);

    // Und danach ist wieder Ruhe: kein Auftrag taucht von selbst auf.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(downloads.jobFor(theWork().id), isNull);
  });

  test('wegräumen während des Holens stürzt nicht ab', () async {
    // Die Fortschrittsmeldungen laufen weiter, während der Auftrag von außen
    // verschwindet. Sie griffen mit `!` auf den Eintrag zu — und der
    // Fehlerbehandler daneben genauso, er wäre an derselben Stelle ein
    // zweites Mal geflogen, diesmal unbehandelt.
    unawaited(downloads.download(theWork()));
    for (var attempt = 0; attempt < 200; attempt++) {
      if (downloads.jobFor(theWork().id) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await downloads.remove(theWork().id);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Kein Auftrag mehr, und vor allem: keine Ausnahme unterwegs.
    expect(downloads.jobFor(theWork().id), isNull);
    // Und nichts gilt als mitgenommen, was gerade gelöscht wurde.
    expect(downloads.isSecured(theWork().id), isFalse);
  });
}
