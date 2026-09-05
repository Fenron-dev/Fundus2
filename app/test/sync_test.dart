import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/features/settings/settings_screen.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;

/// The sync as the app drives it.
///
/// The protocol itself is covered in `packages/client`; what is tried here is
/// the part the app owns — which library on the other side answers for the
/// vault that is open, what gets remembered about a connection, and what the
/// person is told when it does not work. The real server handler answers, in
/// this process rather than over a socket, so the test cannot drift away from
/// the protocol it is meant to speak.
void main() {
  late Directory temporary;
  late LibraryController library;
  late AppSettings settings;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late FundusServerHandler server;
  late String workId;
  late String fileId;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-app-sync-');

    final source = Directory('${temporary.path}/meine');
    final mine = await _library(source);
    workId = mine.listWorks().single.id;
    fileId = mine.playbackTracks(workId).single.fileId;
    mine.close();

    library = LibraryController();
    await library.open(source);

    final copy = Directory('${temporary.path}/ihre');
    await _copyDirectory(source, copy);
    theirs = await FundusLibrary.open(copy);

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    server = FundusServerHandler(
      token: 'geheim',
      serverId: 'server-test',
      serverName: 'Der andere Rechner',
      registry: registry,
    );
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    registry.close();
    await temporary.delete(recursive: true);
  });

  SyncController controller({String token = 'geheim'}) => SyncController(
    settings: settings,
    library: library,
    connect: (peer) => FundusRemoteClient(
      baseUri: peer.baseUri,
      token: token,
      httpClient: _InProcessClient(server.handler),
    ),
  );

  PeerConnection peer({String libraryId = ''}) => PeerConnection(
    serverId: 'server-test',
    name: 'Der andere Rechner',
    baseUrl: 'http://fundus.test',
    token: 'geheim',
    libraryId: libraryId,
  );

  test(
    'der Abgleich findet die Bibliothek und merkt sich, welche es war',
    () async {
      final sync = controller();
      await settings.savePeer(peer());
      library.library!.saveProgress(
        workId: workId,
        fileId: fileId,
        position: const Duration(minutes: 12),
        deviceId: settings.deviceKey,
      );

      final report = await sync.syncWith(settings.peers.single);

      expect(report, isNotNull);
      expect(report!.pushedProgress, 1);
      expect(
        theirs.loadProgress(workId)!.position.numericValue,
        closeTo(12 * 60, 0.001),
      );

      // Was drüben antwortet, ist gelernt: der zweite Durchlauf fragt nicht
      // noch einmal danach.
      final remembered = settings.peers.single;
      expect(remembered.libraryId, theirs.manifest.libraryId);
      expect(remembered.lastSyncAt, isNotNull);
      expect(remembered.lastResult, contains('gesendet'));
    },
  );

  test('der fremde Stand landet in der geöffneten Bibliothek', () async {
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 30),
      deviceId: 'anderes-geraet',
    );

    final report = await controller().syncWith(peer());

    expect(report!.pulledProgress, 1);
    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(30 * 60, 0.001),
    );
  });

  test('ohne geöffnete Bibliothek wird nicht abgeglichen', () async {
    final sync = SyncController(
      settings: settings,
      library: LibraryController(),
      connect: (_) => throw StateError('darf nicht verbunden werden'),
    );

    expect(await sync.syncWith(peer()), isNull);
    // Und die Meldung sagt, was fehlt, statt Unmögliches zu verlangen.
    expect(sync.failure, contains('keine eigene Bibliothek'));
    expect(sync.failure, isNot(contains('dieselbe Bibliothek geöffnet')));
  });

  test(
    'eine fremde Bibliothek wird nicht stillschweigend abgeglichen',
    () async {
      // Die Gegenstelle teilt eine andere Bibliothek als die hier geöffnete.
      final other = Directory('${temporary.path}/fremde');
      final third = await _library(other);
      addTearDown(third.close);
      registry.close();
      registry = FundusLibraryRegistry()..register(third, name: 'Fremdes');
      server = FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        registry: registry,
      );

      final sync = controller();
      expect(await sync.syncWith(peer()), isNull);
      // Sie nennt auch, was drüben stattdessen liegt.
      expect(sync.failure, contains('„Fremdes"'));
    },
  );

  test(
    'ein falsches Token wird als solches gemeldet, nicht als Absturz',
    () async {
      final sync = controller(token: 'falsch');

      expect(await sync.syncWith(peer()), isNull);
      expect(sync.failure, isNotNull);
      expect(sync.isBusy, isFalse);
    },
  );

  test('eine vergessene Verbindung ist weg', () async {
    final sync = controller();
    await settings.savePeer(peer());
    expect(sync.peers, hasLength(1));

    await sync.forget('server-test');

    expect(sync.peers, isEmpty);
  });

  test('ein unlesbarer Kopplungscode wird beim Namen genannt', () async {
    final sync = controller();

    expect(await sync.pair(code: 'hallo', pin: '123456'), isFalse);
    expect(sync.failure, isNotNull);
    expect(sync.peers, isEmpty);
    expect(sync.isBusy, isFalse);
  });

  test(
    'das Journal überlebt den Abgleich und liegt bei der Bibliothek',
    () async {
      final sync = controller();
      // Ein Stand hier, keiner drüben: der geht hinüber.
      library.library!.saveProgress(
        workId: workId,
        fileId: fileId,
        position: const Duration(minutes: 12),
        deviceId: 'hier',
      );

      final report = await sync.syncWith(
        peer(libraryId: theirs.manifest.libraryId),
      );
      expect(report, isNotNull, reason: sync.failure ?? '');
      expect(report!.entries, hasLength(1));

      // Und es steht danach in der Bibliothek, nicht nur im Speicher.
      final journal = await sync.loadJournal(
        peer(libraryId: theirs.manifest.libraryId),
      );
      expect(journal, hasLength(1));
      expect(journal.single.title, 'Der Schacht');
      expect(journal.single.decision, SyncDecision.pushed);

      // Die Grundlinie ist gesetzt, also hat der nächste Lauf nichts zu tun.
      final baseline = await library.library!.loadSyncBaseline('server-test');
      expect(baseline, contains(workId));
    },
  );

  testWidgets('die Einstellungen zeigen, was gekoppelt ist', (tester) async {
    final sync = controller();
    await settings.savePeer(
      peer(libraryId: theirs.manifest.libraryId).copyWith(
        lastSyncAt: DateTime(2026, 3, 14, 9, 5),
        lastResult: '1 Stände gesendet',
      ),
    );

    // Die Seite trägt jetzt beide Hälften — Freigabe und Verbindungen. Auf
    // 800x600 rutscht die zweite aus dem Bild, und eine Liste baut nur, was
    // zu sehen ist.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          sync: sync,
          child: const Scaffold(
            body: SettingsScreen(category: 'synchronisation'),
          ),
        ),
      ),
    );
    // Das Journal wird von der Platte gelesen; in der Scheinzeit von
    // `testWidgets` wird daraus nie etwas, und `pumpAndSettle` wartete
    // sonst auf einen Fortschrittsbalken, der sich für immer dreht.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Der andere Rechner'), findsOneWidget);
    expect(find.textContaining('14.03. 09:05'), findsOneWidget);
    expect(find.text('Jetzt abgleichen'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Koppeln'), findsOneWidget);

    // Und eine getrennte Verbindung verschwindet auch aus der Ansicht.
    await tester.tap(find.byTooltip('Verbindung entfernen'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Der andere Rechner'), findsNothing);
  });
}

/// Speaks HTTP to a shelf handler without a socket in between.
///
/// A real port would work too, but this keeps the test to one process and one
/// clock, and still runs every request through the server's own routing,
/// authentication and JSON.
class _InProcessClient extends http.BaseClient {
  _InProcessClient(this._handler);

  final shelf.Handler _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.bodyBytes : null;
    final response = await _handler(
      shelf.Request(
        request.method,
        request.url,
        headers: request.headers,
        body: body,
      ),
    );
    final bytes = await response.read().expand((chunk) => chunk).toList();
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      contentLength: bytes.length,
    );
  }
}

Future<FundusLibrary> _library(Directory root) async {
  final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
  await work.create(recursive: true);
  await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
  final library = await FundusLibrary.create(root);
  await for (final _ in library.index()) {}
  return library;
}

Future<void> _copyDirectory(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    if (entity is Directory) {
      await Directory('${to.path}/$relative').create(recursive: true);
    } else if (entity is File) {
      final target = File('${to.path}/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    }
  }
}
