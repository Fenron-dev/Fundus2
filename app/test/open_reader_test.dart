import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show FakePageSource, writeArchive;

/// „Öffnen" on a manga must reach the reader. It reached the audio player
/// first, which is a silent file and a progress bar counting seconds that a
/// comic does not have.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late FakeEngine engine;
  late PlaybackController player;
  late ReaderController reader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-open-');
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    await writeArchive(work, 'Band 01.cbz', ['001.jpg', '002.jpg']);
    library = LibraryController();
    settings = AppSettings.inMemory();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
    reader = ReaderController(
      openSource: (path, name) => FakePageSource(name, 12),
    );
  });

  tearDown(() async {
    reader.dispose();
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('ein Manga öffnet den Leser, nicht den Player', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    expect(library.works, isNotEmpty, reason: 'Der Scan hat nichts gefunden');
    final work = library.works.first;

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          reader: reader,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(WorkRoute(work.id));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    await tester.runAsync(() => tester.tap(find.text('Öffnen')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(reader.failure, isNull);
    expect(reader.isOpen, isTrue);
    expect(engine.opened, isEmpty, reason: 'Der Player wurde angeworfen');
    expect(find.textContaining('Seite 1 von 12'), findsWidgets);
  });

  testWidgets('ein EPUB sagt, dass sein Leser noch fehlt', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Directory('${root.path}/Light Novels/Glasmeer').createSync(recursive: true);
    File(
      '${root.path}/Light Novels/Glasmeer/Band 01.epub',
    ).writeAsBytesSync(List.filled(64, 5));

    late FundusScopeState scope;
    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    final novel = library.works.firstWhere(
      (work) => work.mediaType?.id == MediaTypes.novels.id,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          reader: reader,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(WorkRoute(novel.id));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.runAsync(() => scope.play(novel));
    await tester.pump();

    // Nichts an die Audio-Engine, aber auch kein toter Knopf.
    expect(engine.opened, isEmpty);
    expect(reader.isOpen, isFalse);
    expect(player.failure, isNotNull, reason: 'Es gibt keine Rückmeldung');
    expect(find.textContaining('fehlt noch'), findsWidgets);
  });

  testWidgets('ein beschädigtes Archiv sagt, was los ist', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Kein ZIP, nur Bytes mit der richtigen Endung.
    File('${root.path}/Manga/Klingenwind/Band 02.cbz')
      ..createSync()
      ..writeAsBytesSync(List.filled(64, 9));

    final honest = ReaderController();
    addTearDown(honest.dispose);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await honest.open(library.library!, library.works.first);
      // Band 01 ist heil, Band 02 nicht.
      await honest.openVolume(honest.volumes.length - 1);
    });

    expect(honest.volumes, hasLength(2));
    expect(honest.failure, isNotNull);
    expect(honest.pages, isEmpty);
    expect(honest.isOpen, isTrue, reason: 'Der Fehler gehört in den Leser');
  });
}
