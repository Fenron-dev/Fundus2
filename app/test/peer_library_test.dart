import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:archive/archive.dart';
import 'package:fundus/media/peer_file_cache.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus/media/comic_archive.dart';
import 'package:fundus/media/remote_comic_source.dart';
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
  late PeerLibraries peers;

  /// Was der Server gefragt wurde — „wie oft" ist hier die eigentliche
  /// Prüfung.
  late List<String> requests;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-peer-');

    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File(
      '${work.path}/01 - Anfang.mp3',
    ).writeAsBytes(List.filled(2048, 7));

    // Und ein Manga, denn genau der ließ sich vom Handy aus nicht öffnen.
    final manga = Directory('${source.path}/Manga/Klingenwind');
    await manga.create(recursive: true);
    final archive = Archive()
      ..add(ArchiveFile.bytes('001.jpg', List.filled(8, 1)))
      ..add(ArchiveFile.bytes('002.jpg', List.filled(8, 1)));
    await File(
      '${manga.path}/Band 1.cbz',
    ).writeAsBytes(ZipEncoder().encodeBytes(archive));

    theirs = await FundusLibrary.create(source);
    await for (final _ in theirs.index()) {}

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    requests = [];
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        serverName: 'Mac',
        registry: registry,
        requestObserver: (event) =>
            requests.add('${event.method} ${event.resource}'),
      ).handler,
      'localhost',
      0,
    );

    library = LibraryController();
    settings = AppSettings.inMemory();
    peers = PeerLibraries(
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
    expect(await peers.connect(peer()), isTrue, reason: peers.failure ?? '');

    expect(library.isOpen, isTrue);
    expect(
      library.works.map((work) => work.title),
      containsAll(['Der Schacht', 'Klingenwind']),
    );
    // Der Vault heißt nach dem, was er ist: der eigene, in dem die
    // Bibliotheken mehrerer Geräte zusammenlaufen.
    expect(library.displayName, 'Meine Werke');
    // Und das Werk weiß, von welchem Gerät es kommt.
    expect(library.works.first.summary.sourceId, 'peer-server-test');
  });

  test('das Werk sagt, dass es von woanders kommt', () async {
    await peers.connect(peer());

    expect(
      library.works
          .firstWhere((work) => work.title == 'Der Schacht')
          .origin
          .name,
      'stream',
    );
  });

  test('ein gespiegeltes CBZ gilt dem Leser als lesbar', () async {
    await peers.connect(peer());
    final comic = library.works.firstWhere(
      (work) => work.title == 'Klingenwind',
    );
    final volumes = library.library!.playbackTracks(comic.id);

    // Und die App schickt es überhaupt an den Leser.
    expect(ReaderController.handles(comic), isTrue);
    expect(volumes, isNotEmpty);
    // Der Fehler war genau hier: der gespiegelte Pfad hieß `peer/<id>` und
    // trug keine Endung, also war für den Leser nichts davon ein Comic.
    expect(volumes.first.title, endsWith('.cbz'));
    expect(ReaderController.isReadableFile(volumes.first.title), isTrue);
    expect(volumes.first.relativePath, endsWith('.cbz'));
  });

  test('ein Comic wird seitenweise gelesen, nicht am Stück geholt', () async {
    await peers.connect(peer());
    final comic = library.works.firstWhere(
      (work) => work.title == 'Klingenwind',
    );
    final volume = library.library!.playbackTracks(comic.id).first;

    final pageRoom = Directory('${temporary.path}/seiten');
    final source = RemoteComicPageSource(
      client: peers.connected.single.client,
      libraryId: peers.connected.single.libraryId,
      fileId: volume.fileId,
      name: volume.title,
      cacheDirectory: pageRoom,
    );
    addTearDown(source.dispose);

    final pages = await source.pages();
    expect(pages, hasLength(2));

    // Eine Seite kommt allein — und nur sie liegt danach hier.
    final materialised = await source.materialize([pages.first]);
    expect(materialised, hasLength(1));
    expect(await File(materialised[pages.first.id]!).exists(), isTrue);
    expect(pageRoom.listSync().whereType<File>(), hasLength(1));
  });

  test('der Leser bekommt das Archiv und findet seine Seiten', () async {
    await peers.connect(peer());
    final comic = library.works.firstWhere(
      (work) => work.title == 'Klingenwind',
    );
    final volume = library.library!.playbackTracks(comic.id).first;

    final cache = PeerFileCache(
      proxy: peers.connected.single.proxy,
      directory: Directory('${temporary.path}/leser-cache'),
    );
    final path = await cache.fileFor(volume);
    final source = ArchiveComicPageSource(path, name: volume.title);
    addTearDown(source.dispose);

    expect(await source.pages(), hasLength(2));
  });

  test('der Player bekommt eine Adresse, keine Datei', () async {
    await peers.connect(peer());
    final track = library.library!
        .playbackTracks(_audiobook(library).id)
        .single;

    expect(track.isRemote, isTrue);
    final uri = peers.connected.single.proxy.uriFor(
      track.fileId,
      extension: '.mp3',
    );
    expect(uri.host, '127.0.0.1');
    expect(uri.path, endsWith('.mp3'));
  });

  test('ein Leser bekommt die Datei wirklich hierher', () async {
    await peers.connect(peer());
    final track = library.library!
        .playbackTracks(_audiobook(library).id)
        .single;

    final cache = PeerFileCache(
      proxy: peers.connected.single.proxy,
      directory: Directory('${temporary.path}/cache'),
    );
    final path = await cache.fileFor(track);

    expect(await File(path).length(), 2048);
    // Und beim zweiten Mal wird nichts noch einmal geholt.
    expect(await cache.fileFor(track), path);
  });

  test('der Lesestand geht zurück zum Mac', () async {
    await peers.connect(peer());
    final workId = _audiobook(library).id;
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

  test('nachgeholt wird nur, was sich drüben bewegt hat', () async {
    await peers.connect(peer());
    final workId = _audiobook(library).id;
    final fileId = theirs.playbackTracks(workId).single.fileId;
    final sync = SyncController(settings: settings, library: library);
    addTearDown(sync.dispose);

    // Beim ersten Mal ist alles neu — der Stand vom Mac kommt herüber.
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mac',
    );
    final first = await sync.pullRecent();

    expect(first, contains(workId));
    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(12 * 60, 0.001),
    );

    // Und ohne neue Bewegung wird nichts mehr geholt: das ist der Grund,
    // warum das von selbst laufen darf.
    expect(await sync.pullRecent(), isEmpty);

    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 31),
      deviceId: 'mac',
    );
    expect(await sync.pullRecent(), contains(workId));
    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(31 * 60, 0.001),
    );
  });

  test('ein Auffrischen ohne Neues kostet eine einzige Frage', () async {
    // Der Fall aus dem Protokoll: acht Anfragen pro Sekunde über Minuten.
    // Der Grund war, dass jeder Lauf alles holte *und* zurückschob — und
    // jedes Zurückschieben drüben einen neuen Zeitstempel setzte.
    await peers.connect(peer());
    final workId = _audiobook(library).id;
    final fileId = theirs.playbackTracks(workId).single.fileId;
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mac',
    );
    final sync = SyncController(settings: settings, library: library);
    addTearDown(sync.dispose);

    expect(await sync.pullRecent(), contains(workId));
    final afterFirst = requests.length;

    // Zweite Runde: nichts hat sich bewegt.
    expect(await sync.pullRecent(), isEmpty);
    final second = requests.skip(afterFirst).toList();

    // Genau eine Frage — „was hat sich geändert?" —, und keine einzige
    // Notiz- oder Schreibanfrage.
    expect(second, ['GET progress']);
    expect(requests.where((entry) => entry.contains('annotations')), isEmpty);
    expect(requests.where((entry) => entry.startsWith('PUT')), isEmpty);
  });

  test(
    'was hier weiter ist, wird nicht überschrieben, sondern gefragt',
    () async {
      await peers.connect(peer());
      final workId = _audiobook(library).id;
      final fileId = theirs.playbackTracks(workId).single.fileId;
      // Drüben neuer, hier weiter: das ist der einzige Fall, den niemand
      // entscheiden kann, ohne zu fragen.
      library.library!.saveProgress(
        workId: workId,
        fileId: fileId,
        position: const Duration(minutes: 40),
        deviceId: 'handy',
      );
      theirs.saveProgress(
        workId: workId,
        fileId: fileId,
        position: const Duration(minutes: 5),
        deviceId: 'mac',
      );
      final sync = SyncController(settings: settings, library: library);
      addTearDown(sync.dispose);

      await sync.pullRecent();

      // Der eigene Stand bleibt stehen …
      expect(
        library.library!.loadProgress(workId)!.position.numericValue,
        closeTo(40 * 60, 1),
      );
      // … und die Frage liegt für das nächste Öffnen bereit.
      expect(library.library!.progressChoice(workId), isNotNull);
    },
  );

  test('der Zeitpunkt eines Standes überlebt die Reise', () async {
    await peers.connect(peer());
    final workId = _audiobook(library).id;
    final fileId = library.library!.playbackTracks(workId).single.fileId;
    library.library!.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 17),
      deviceId: 'handy',
    );
    final mine = library.library!.loadProgress(workId)!.updatedAt;

    final sync = SyncController(settings: settings, library: library);
    await sync.syncWith(settings.peers.single);

    // Drüben steht, wann gehört wurde — nicht, wann es dort ankam. Sonst
    // sortiert jedes Gerät „Zuletzt gesehen" anders.
    expect(
      theirs.loadProgress(workId)!.updatedAt.difference(mine).abs(),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('ein schlafender Mac leert die Bibliothek nicht', () async {
    await peers.connect(peer());
    final before = library.works.length;

    await socket.close(force: true);
    await peers.refresh();

    // Die Liste steht noch; nur die Meldung sagt, was los ist.
    expect(library.works, hasLength(before));
    expect(peers.failure, isNotNull);
  });
}

/// Das Hörbuch unter den gespiegelten Werken.
WorkView _audiobook(LibraryController library) =>
    library.works.firstWhere((work) => work.title == 'Der Schacht');
