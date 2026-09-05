import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/download_controller.dart';
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
}
