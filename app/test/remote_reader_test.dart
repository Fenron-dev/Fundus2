import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Opening a mirrored comic the way the app opens it.
///
/// The peer tests reach into the controllers; this one goes through the
/// scope, which is where the wiring lives — and where a missing piece made
/// every reader answer „zu diesem Gerät besteht keine Verbindung" for a
/// machine that was answering perfectly well.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraries peers;

  setUp(() async {
    // Das Widget-Binding hängt einen Schein-HTTP-Client davor, der alles mit
    // 400 beantwortet. Hier soll aber wirklich über die Leitung gegangen
    // werden — das ist der Punkt der Übung.
    HttpOverrides.global = null;
    temporary = await Directory.systemTemp.createTemp('fundus-remote-read-');
    final source = Directory('${temporary.path}/mac');
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

    registry = FundusLibraryRegistry()..register(theirs, name: 'Manga');
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: 'mac',
        serverName: 'Mac',
        registry: registry,
      ).handler,
      'localhost',
      0,
    );

    library = LibraryController();
    settings = AppSettings.inMemory();
    await settings.savePeer(
      PeerConnection(
        serverId: 'mac',
        name: 'Mac',
        baseUrl: 'http://localhost:${socket.port}',
        token: 'geheim',
      ),
    );
    peers = PeerLibraries(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/handy'),
    );
  });

  tearDown(() async {
    peers.dispose();
    library.dispose();
    await socket.close(force: true);
    registry.unregister(theirs.manifest.libraryId);
    theirs.close();
    await temporary.delete(recursive: true);
  });

  testWidgets('ein Manga vom Server geht auf', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          peerLibraries: peers,
          supportRoot: Directory('${temporary.path}/speicher'),
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.runAsync(scope.connectPairedMachines);
    scope.navigation.reset(const DashboardRoute());
    await tester.pump();

    final comic = library.works.single;
    expect(comic.title, 'Klingenwind');

    await tester.runAsync(() => scope.play(comic));
    await tester.pump();

    // Genau hier stand vorher „zu diesem Gerät besteht keine Verbindung",
    // obwohl der Mac gerade den Katalog geliefert hatte.
    expect(scope.reader.failure, isNull);
    expect(scope.reader.isOpen, isTrue);
    expect(scope.reader.pages, hasLength(2));
  });
}
