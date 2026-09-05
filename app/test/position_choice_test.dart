import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'sync_test.dart' show InProcessClient;

/// Zwei Geräte, zwei Stände.
///
/// Der Abgleich muss wählen — eine Position lässt sich nicht mitteln, und
/// mitten im Lauf nach Werken zu fragen, an die gerade niemand denkt, ist
/// keine Frage. Die Seite, die verliert, wird aber nicht mehr weggeworfen:
/// sie wird gestellt, wenn jemand das Werk öffnet.
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
    temporary = await Directory.systemTemp.createTemp('fundus-choice-');
    final source = Directory('${temporary.path}/meine');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
    final mine = await FundusLibrary.create(source);
    await mine.index().drain<void>();
    workId = mine.listWorks().single.id;
    fileId = mine.playbackTracks(workId).single.fileId;
    mine.close();

    library = LibraryController();
    await library.open(source);

    final copy = Directory('${temporary.path}/ihre');
    await copy.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relative = entity.path.substring(source.path.length + 1);
      if (entity is Directory) {
        await Directory('${copy.path}/$relative').create(recursive: true);
      } else if (entity is File) {
        final target = File('${copy.path}/$relative');
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
    }
    theirs = await FundusLibrary.open(copy);
    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    server = FundusServerHandler(
      token: 'geheim',
      serverId: 'server-test',
      serverName: 'mac',
      registry: registry,
    );
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    registry.close();
    await temporary.delete(recursive: true);
  });

  PeerConnection peer() => const PeerConnection(
    serverId: 'server-test',
    name: 'mac',
    baseUrl: 'http://fundus.test',
    token: 'geheim',
  );

  SyncController controller() => SyncController(
    settings: settings,
    library: library,
    connect: (entry) => FundusRemoteClient(
      baseUri: entry.baseUri,
      token: 'geheim',
      httpClient: InProcessClient(server.handler),
    ),
  );

  /// Beide Seiten stehen woanders; der Abgleich entscheidet sich für eine.
  Future<void> disagree() async {
    library.library!.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: settings.deviceKey,
    );
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 40),
      deviceId: 'mac-geraet',
    );
    await controller().syncWith(peer());
  }

  test('die Seite, die verliert, bleibt als Frage stehen', () async {
    await disagree();

    final open = library.library!.progressChoice(workId);
    expect(open, isNotNull);
    expect(
      open!.position.numericValue,
      anyOf(closeTo(12 * 60, 1), closeTo(40 * 60, 1)),
    );
    // Und sie sagt, von wo sie kommt — eine Geräte-ID beantwortet keine Frage.
    expect(open.origin, isNotEmpty);
  });

  test('gleiche Stände sind keine Frage', () async {
    library.library!.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: settings.deviceKey,
    );
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mac-geraet',
    );

    await controller().syncWith(peer());

    expect(library.library!.progressChoice(workId), isNull);
  });

  testWidgets('„immer die weiteste Stelle" fragt kein zweites Mal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(disagree);
    final player = PlaybackController(engine: FakeEngine());
    addTearDown(player.dispose);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final asking = scope.settlePosition(library.library!, library.works.single);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Künftig immer die weiteste Stelle'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Ab '));
    await tester.pumpAndSettle();
    await asking;

    expect(settings.alwaysFurthestPosition, isTrue);

    // Und beim nächsten Mal steht die Frage gar nicht mehr auf.
    await tester.runAsync(disagree);
    final again = scope.settlePosition(library.library!, library.works.single);
    await tester.pumpAndSettle();
    expect(find.text('Wo weitermachen?'), findsNothing);
    await again;
    expect(library.library!.progressChoice(workId), isNull);
  });

  testWidgets('beim Öffnen wird gefragt, und die Antwort gilt', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(disagree);
    final other = library.library!.progressChoice(workId)!;
    final player = PlaybackController(engine: FakeEngine());
    addTearDown(player.dispose);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final asking = scope.settlePosition(library.library!, library.works.single);
    await tester.pumpAndSettle();

    expect(find.text('Wo weitermachen?'), findsOneWidget);
    expect(find.textContaining(other.origin), findsWidgets);
    // Die weitere Stelle ist vorgewählt — meistens die Antwort. Hier wird
    // aber ausdrücklich die andere gewählt, denn genau das ist der Sinn.
    expect(find.text('weiteste'), findsOneWidget);
    await tester.tap(find.textContaining(other.origin).last);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Ab '));
    await tester.pumpAndSettle();
    await asking;

    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(other.position.numericValue!, 1),
    );
    expect(
      library.library!.progressChoice(workId),
      isNull,
      reason: 'beantwortet ist beantwortet',
    );
  });
}
