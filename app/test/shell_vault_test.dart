import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus/data/work_filter.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// The phone as a shell where several Fundus libraries come together.
///
/// It has no media of its own and never will. What it has is an index: the
/// catalogues of the machines it is paired with, each under a source of its
/// own, in one vault — and the ordinary filter is what separates them again.
void main() {
  late Directory temporary;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraries peers;
  final servers = <String, HttpServer>{};
  final vaults = <String, FundusLibrary>{};
  final registries = <String, FundusLibraryRegistry>{};

  /// A machine with one work on it.
  Future<PeerConnection> machine(String id, String title) async {
    final root = Directory('${temporary.path}/$id');
    final work = Directory('${root.path}/Hörbücher/Karl May/$title');
    await work.create(recursive: true);
    await File('${work.path}/01.mp3').writeAsBytes(List.filled(512, 1));
    final vault = await FundusLibrary.create(root);
    await for (final _ in vault.index()) {}
    vaults[id] = vault;

    final registry = FundusLibraryRegistry()..register(vault, name: id);
    registries[id] = registry;
    final socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: id,
        serverName: id,
        registry: registry,
      ).handler,
      'localhost',
      0,
    );
    servers[id] = socket;
    return PeerConnection(
      serverId: id,
      name: id,
      baseUrl: 'http://localhost:${socket.port}',
      token: 'geheim',
    );
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-shell-vault-');
    library = LibraryController();
    settings = AppSettings.inMemory();
    peers = PeerLibraries(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/handy'),
    );
  });

  tearDown(() async {
    peers.dispose();
    library.dispose();
    for (final socket in servers.values) {
      await socket.close(force: true);
    }
    for (final registry in registries.entries) {
      registry.value.unregister(vaults[registry.key]!.manifest.libraryId);
    }
    for (final vault in vaults.values) {
      vault.close();
    }
    servers.clear();
    vaults.clear();
    registries.clear();
    await temporary.delete(recursive: true);
  });

  test('ohne eigene Bibliothek legt das Handy sich eine an', () async {
    expect(library.isOpen, isFalse);

    final mac = await machine('mac', 'Der Schacht');
    await settings.savePeer(mac);
    await peers.connectAll();

    expect(library.isOpen, isTrue);
    expect(library.works.single.title, 'Der Schacht');
    // Und niemand musste „eine Bibliothek anlegen" verstehen.
    expect(library.displayName, 'Meine Werke');
  });

  test('zwei Server laufen in einem Vault zusammen', () async {
    await settings.savePeer(await machine('mac', 'Der Schacht'));
    await settings.savePeer(await machine('nas', 'Der Ölprinz'));

    await peers.connectAll();

    expect(
      library.works.map((work) => work.title),
      containsAll(['Der Schacht', 'Der Ölprinz']),
    );
    expect(peers.connected, hasLength(2));
    // Jedes Werk weiß, von welchem Gerät es kommt.
    final sources = library.works.map((work) => work.summary.sourceId).toSet();
    expect(sources, {'peer-mac', 'peer-nas'});
  });

  test('das Gerät ist ein Filter, kein zweiter Bildschirm', () async {
    await settings.savePeer(await machine('mac', 'Der Schacht'));
    await settings.savePeer(await machine('nas', 'Der Ölprinz'));
    await peers.connectAll();

    const nurMac = WorkFilter(sourceId: 'peer-mac');
    expect(nurMac.apply(library.works).single.title, 'Der Schacht');

    const alle = WorkFilter();
    expect(alle.apply(library.works), hasLength(2));
  });

  test('ein schlafender Server nimmt seine Werke nicht mit', () async {
    await settings.savePeer(await machine('mac', 'Der Schacht'));
    await settings.savePeer(await machine('nas', 'Der Ölprinz'));
    await peers.connectAll();

    await servers['nas']!.close(force: true);
    await peers.refresh();

    // Die Werke stehen weiter da — nur zu holen sind sie gerade nicht.
    expect(library.works, hasLength(2));
    final nas = library.sources.firstWhere((s) => s.id == 'peer-nas');
    expect(nas.status, LibrarySourceStatus.unreachable);
    // Und der Mac ist davon unberührt.
    expect(peers.peerFor('mac')!.connection, FundusConnectionState.connected);
  });

  test('der Lesestand geht an das Gerät, dem das Werk gehört', () async {
    await settings.savePeer(await machine('mac', 'Der Schacht'));
    await settings.savePeer(await machine('nas', 'Der Ölprinz'));
    await peers.connectAll();

    final schacht = library.works.firstWhere(
      (work) => work.title == 'Der Schacht',
    );
    library.library!.saveProgress(
      workId: schacht.id,
      fileId: library.library!.playbackTracks(schacht.id).single.fileId,
      position: const Duration(minutes: 8),
      deviceId: 'handy',
    );

    final sync = SyncController(settings: settings, library: library);
    final report = await sync.syncWith(
      settings.peers.firstWhere((peer) => peer.serverId == 'mac'),
    );

    expect(report, isNotNull, reason: sync.failure ?? '');
    expect(report!.pushedProgress, 1);
    expect(
      vaults['mac']!.loadProgress(schacht.id)!.position.numericValue,
      closeTo(8 * 60, 0.001),
    );
    // Und der andere Server wurde damit gar nicht erst behelligt.
    expect(report.skipped, 0);
  });

  test('der Stand vom Server kommt beim Verbinden mit', () async {
    final mac = await machine('mac', 'Der Schacht');
    await settings.savePeer(mac);

    // Auf dem Server steht das Werk schon bei Minute 30.
    final vault = vaults['mac']!;
    final workId = vault.listWorks().single.id;
    vault.saveProgress(
      workId: workId,
      fileId: vault.playbackTracks(workId).single.fileId,
      position: const Duration(minutes: 30),
      deviceId: 'mac',
    );

    await peers.connectAll();
    // Der Katalog allein reicht nicht: ohne die Stände behauptet jedes Werk,
    // es sei nie geöffnet worden.
    final sync = SyncController(settings: settings, library: library);
    await sync.syncAll();

    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(30 * 60, 0.001),
    );
  });

  test('ein vergessenes Gerät nimmt seine Werke mit', () async {
    await settings.savePeer(await machine('mac', 'Der Schacht'));
    await settings.savePeer(await machine('nas', 'Der Ölprinz'));
    await peers.connectAll();
    expect(library.works, hasLength(2));

    await peers.forget('nas');

    expect(library.works.single.title, 'Der Schacht');
    expect(settings.peers.map((peer) => peer.serverId), ['mac']);
  });
}
