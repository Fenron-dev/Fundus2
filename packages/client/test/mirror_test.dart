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
  HttpServer? socketOrNull;
  FundusLibraryRegistry? registryOrNull;

  /// Publishes the library, replacing any earlier server.
  ///
  /// The shared view reads the work list once when it is made, so anything
  /// changed on that side needs a fresh one — which is also what happens in
  /// life, where the other machine is restarted or rescans.
  Future<void> share() async {
    await socketOrNull?.close(force: true);
    // Not `close()`: the registry only borrows this library, and closing it
    // would take the library down with it.
    registryOrNull?.unregister(theirs.manifest.libraryId);
    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    registryOrNull = registry;
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
    socketOrNull = socket;
    client.close();
    client = FundusRemoteClient(
      baseUri: Uri.parse('http://localhost:${socket.port}'),
      token: 'geheim',
    );
  }

  setUp(() async {
    socketOrNull = null;
    registryOrNull = null;
    client = FundusRemoteClient(
      baseUri: Uri.parse('http://localhost:1'),
      token: 'geheim',
    );
    temporary = await Directory.systemTemp.createTemp('fundus-mirror-');

    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    for (final name in ['01 - Anfang.mp3', '02 - Mitte.mp3']) {
      await File('${work.path}/$name').writeAsBytes(List.filled(64, 1));
    }
    await File('${work.path}/cover.jpg').writeAsBytes([255, 216, 255, 217]);
    theirs = await FundusLibrary.create(source);
    await for (final _ in theirs.index()) {}

    // Das Telefon: ein Vault ohne eine einzige Mediendatei.
    mine = await FundusLibrary.create(Directory('${temporary.path}/handy'));

    await share();
  });

  tearDown(() async {
    client.close();
    await socket.close(force: true);
    registry.unregister(theirs.manifest.libraryId);
    theirs.close();
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
    expect(mine.listWorks(), hasLength(1));

    // Drüben ist das Werk weg — Ordner gelöscht, neu eingelesen.
    await Directory(
      '${theirs.root.path}/Hörbücher/Karl May',
    ).delete(recursive: true);
    await for (final _ in theirs.index()) {}
    await share();

    final report = await FundusCatalogueMirror(
      library: mine,
      client: client,
      libraryId: theirs.manifest.libraryId,
      sourceId: 'peer-server-test',
    ).run();

    expect(report.removed, 1);
    expect(mine.listWorks(), isEmpty);
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

  test(
    'ein zweiter Durchlauf holt nichts, wenn sich nichts geändert hat',
    () async {
      registerPeer();
      final first = await mirror().run();
      expect(first.written, 1);

      // Das Verzeichnis sagt: alles beim Alten. Also kommt kein Werk herüber.
      final second = await mirror().run();
      expect(second.written, 0);
      expect(second.removed, 0);
      // Und die Bibliothek steht unverändert da.
      expect(mine.listWorks(), hasLength(1));
    },
  );

  test(
    'fehlende Cover werden auch nach dem ersten 60er-Batch weitergeholt',
    () async {
      final root = Directory('${theirs.root.path}/Hörbücher/Katalog');
      for (var index = 0; index < 60; index++) {
        final work = Directory('${root.path}/Werk-$index');
        await work.create(recursive: true);
        await File('${work.path}/01.mp3').writeAsBytes([index]);
        await File('${work.path}/cover.jpg').writeAsBytes([255, 216, 255, 217]);
      }
      await for (final _ in theirs.index()) {}
      await share();
      registerPeer();

      await mirror().run();
      expect(
        mine.listWorks().where((work) => work.coverPath != null),
        hasLength(60),
      );

      await mirror().run();
      expect(
        mine.listWorks().where((work) => work.coverPath != null),
        hasLength(61),
      );
    },
  );

  test('nur das geänderte Werk wird geholt', () async {
    // Ein zweites Werk drüben, damit es etwas zu unterscheiden gibt.
    final second = Directory(
      '${theirs.root.path}/Hörbücher/Karl May/Der Ölprinz',
    );
    await second.create(recursive: true);
    await File(
      '${second.path}/01 - Anfang.mp3',
    ).writeAsBytes(List.filled(64, 2));
    await for (final _ in theirs.index()) {}
    await share();

    mine.registerPeerSource(
      sourceId: 'peer-server-test',
      displayName: 'Mac',
      libraryId: theirs.manifest.libraryId,
      baseUrl: 'http://localhost:${socket.port}',
    );
    await mirror().run();
    expect(mine.listWorks(), hasLength(2));

    // Ein Titel ändert sich; das andere Werk bleibt, wie es war.
    final changed = theirs.listWorks().firstWhere(
      (work) => work.title == 'Der Ölprinz',
    );
    await theirs.updateWorkMetadata(
      workId: changed.id,
      title: 'Der Ölprinz (neu)',
      authors: [changed.author],
    );
    await share();

    final delta = FundusCatalogueMirror(
      library: mine,
      client: client,
      libraryId: theirs.manifest.libraryId,
      sourceId: 'peer-server-test',
    );
    final report = await delta.run();

    // Genau eines — nicht der ganze Katalog.
    expect(report.written, 1);
    expect(report.removed, 0);
    expect(
      mine.listWorks().map((work) => work.title),
      containsAll(['Der Schacht', 'Der Ölprinz (neu)']),
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
