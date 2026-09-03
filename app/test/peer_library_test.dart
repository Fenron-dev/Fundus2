import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus/media/peer_file_cache.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// A phone opening the library of a Mac it is paired with.
///
/// This is the case the sync could not answer: the library is over there and
/// is never coming over here. What is tried is the whole chain — the
/// catalogue arriving as ordinary works, a file being fetched for a reader,
/// and the reading state going back the other way.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraryController peers;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-peer-');

    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File(
      '${work.path}/01 - Anfang.mp3',
    ).writeAsBytes(List.filled(2048, 7));
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
    peers = PeerLibraryController(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/handy-speicher'),
    );
  });

  tearDown(() async {
    peers.dispose();
    library.dispose();
    await socket.close(force: true);
    registry.close();
    await temporary.delete(recursive: true);
  });

  PeerConnection peer() => PeerConnection(
    serverId: 'server-test',
    name: 'Mac',
    baseUrl: 'http://localhost:${socket.port}',
    token: 'geheim',
  );

  test('die Bibliothek des Macs steht danach in der normalen Liste', () async {
    expect(await peers.open(peer()), isTrue, reason: peers.failure ?? '');

    expect(library.isOpen, isTrue);
    expect(library.works, hasLength(1));
    expect(library.works.single.title, 'Der Schacht');
    // Und sie heißt, wie das Gerät heißt — nicht wie ihr Ordner.
    expect(library.displayName, 'Mac');
  });

  test('das Werk sagt, dass es von woanders kommt', () async {
    await peers.open(peer());

    expect(library.works.single.origin.name, 'stream');
  });

  test('der Player bekommt eine Adresse, keine Datei', () async {
    await peers.open(peer());
    final track = library.library!
        .playbackTracks(library.works.single.id)
        .single;

    expect(track.isRemote, isTrue);
    final uri = peers.proxy!.uriFor(track.fileId, extension: '.mp3');
    expect(uri.host, '127.0.0.1');
    expect(uri.path, endsWith('.mp3'));
  });

  test('ein Leser bekommt die Datei wirklich hierher', () async {
    await peers.open(peer());
    final track = library.library!
        .playbackTracks(library.works.single.id)
        .single;

    final cache = PeerFileCache(
      proxy: peers.proxy!,
      directory: Directory('${temporary.path}/cache'),
    );
    final path = await cache.fileFor(track);

    expect(await File(path).length(), 2048);
    // Und beim zweiten Mal wird nichts noch einmal geholt.
    expect(await cache.fileFor(track), path);
  });

  test('der Lesestand geht zurück zum Mac', () async {
    await peers.open(peer());
    final workId = library.works.single.id;
    final fileId = library.library!.playbackTracks(workId).single.fileId;
    library.library!.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 17),
      deviceId: 'handy',
    );

    final sync = SyncController(settings: settings, library: library);
    final report = await sync.syncWith(settings.peers.single);

    expect(report, isNotNull, reason: sync.failure ?? '');
    expect(report!.pushedProgress, 1);
    expect(
      theirs.loadProgress(workId)!.position.numericValue,
      closeTo(17 * 60, 0.001),
    );
  });

  test('ein schlafender Mac leert die Bibliothek nicht', () async {
    await peers.open(peer());
    expect(library.works, hasLength(1));

    await socket.close(force: true);
    expect(await peers.refresh(), isFalse);

    // Die Liste steht noch; nur die Meldung sagt, was los ist.
    expect(library.works, hasLength(1));
    expect(peers.failure, isNotNull);
  });
}
