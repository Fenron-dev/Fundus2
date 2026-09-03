import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// A device with no media of its own, holding another one's catalogue.
///
/// This is the phone: an empty vault that is an index and nothing else, and
/// a Fundus on the network that has the files. What is tried here is that the
/// works arrive in the ordinary tables — so the ordinary library view finds
/// them — and that a mirror stays a mirror when the other side changes.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late FundusLibrary mine;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late FundusRemoteClient client;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-mirror-');

    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    for (final name in ['01 - Anfang.mp3', '02 - Mitte.mp3']) {
      await File('${work.path}/$name').writeAsBytes(List.filled(64, 1));
    }
    theirs = await FundusLibrary.create(source);
    await for (final _ in theirs.index()) {}

    // Das Telefon: ein Vault ohne eine einzige Mediendatei.
    mine = await FundusLibrary.create(Directory('${temporary.path}/handy'));

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    final handler = FundusServerHandler(
      token: 'geheim',
      serverId: 'server-test',
      serverName: 'Mac',
      registry: registry,
    );
    socket = await shelf_io.serve(handler.handler, 'localhost', 0);
    client = FundusRemoteClient(
      baseUri: Uri.parse('http://localhost:${socket.port}'),
      token: 'geheim',
    );
  });

  tearDown(() async {
    client.close();
    await socket.close(force: true);
    registry.close();
    mine.close();
    await temporary.delete(recursive: true);
  });

  FundusCatalogueMirror mirror() => FundusCatalogueMirror(
    library: mine,
    client: client,
    libraryId: theirs.manifest.libraryId,
    sourceId: 'peer-server-test',
  );

  void registerPeer() => mine.registerPeerSource(
    sourceId: 'peer-server-test',
    displayName: 'Mac',
    libraryId: theirs.manifest.libraryId,
    baseUrl: 'http://localhost:${socket.port}',
  );

  test('der Katalog nennt Werke und ihre Dateien in einer Antwort', () async {
    final catalogue = await client.catalogue(theirs.manifest.libraryId);

    expect(catalogue, hasLength(1));
    expect(catalogue.single.title, 'Der Schacht');
    expect(catalogue.single.files, hasLength(2));
    expect(catalogue.single.files.first.filename, '01 - Anfang.mp3');
  });

  test('gespiegelte Werke stehen in der ganz normalen Liste', () async {
    registerPeer();
    final report = await mirror().run();

    expect(report.written, 1);
    final works = mine.listWorks();
    expect(works, hasLength(1));
    expect(works.single.title, 'Der Schacht');
    // Und mit derselben Kennung wie drüben — sonst gingen Lesestände daneben.
    expect(works.single.id, theirs.listWorks().single.id);
  });

  test('die Spuren sagen, dass sie woanders liegen', () async {
    registerPeer();
    await mirror().run();

    final tracks = mine.playbackTracks(mine.listWorks().single.id);
    expect(tracks, hasLength(2));
    expect(tracks.first.isRemote, isTrue);
    expect(tracks.first.sourceId, 'peer-server-test');
    // Kein erfundener Pfad auf diesem Gerät.
    expect(tracks.first.absolutePath, isEmpty);
    // Aber dieselbe Dateikennung, damit der Server sie ausliefern kann.
    expect(
      tracks.first.fileId,
      theirs.playbackTracks(theirs.listWorks().single.id).first.fileId,
    );
  });

  test('ein zweiter Durchlauf verdoppelt nichts', () async {
    registerPeer();
    await mirror().run();
    await mirror().run();

    expect(mine.listWorks(), hasLength(1));
    expect(mine.playbackTracks(mine.listWorks().single.id), hasLength(2));
  });

  test('was drüben verschwindet, verschwindet auch hier', () async {
    registerPeer();
    await mirror().run();

    final gone = RemoteWorkRecord(
      id: 'gibt-es-nur-hier',
      kind: 'audiobook',
      title: 'Verirrt',
    );
    mine.mirrorRemoteCatalogue(sourceId: 'peer-server-test', works: [gone]);
    expect(mine.listWorks().single.title, 'Verirrt');

    final report = await mirror().run();
    expect(report.removed, 1);
    expect(mine.listWorks().single.title, 'Der Schacht');
  });

  test('der Lesestand überlebt ein Werk, das kurz fehlt', () async {
    registerPeer();
    await mirror().run();
    final workId = mine.listWorks().single.id;
    final fileId = mine.playbackTracks(workId).first.fileId;
    mine.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 9),
      deviceId: 'handy',
    );

    // Die Gegenstelle ist kurz leer — abgeschaltet, umbenannt, was auch immer.
    mine.mirrorRemoteCatalogue(sourceId: 'peer-server-test', works: const []);
    expect(mine.listWorks(), isEmpty);

    await mirror().run();
    expect(
      mine.loadProgress(workId)!.position.numericValue,
      closeTo(9 * 60, 0.001),
    );
  });

  test('eine unerreichbare Quelle leert die Bibliothek nicht', () async {
    registerPeer();
    await mirror().run();

    mine.setSourceReachable('peer-server-test', reachable: false);

    // Die Werke bleiben stehen; nur ihre Herkunft sagt, dass sie gerade
    // nicht zu holen sind.
    expect(mine.listWorks(), hasLength(1));
    expect(
      mine.listSources().firstWhere((s) => s.id == 'peer-server-test').status,
      LibrarySourceStatus.unreachable,
    );
  });
}
