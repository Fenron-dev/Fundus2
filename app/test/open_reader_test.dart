import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/features/reader/reader_screen.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show FakePageSource, writeArchive;
import 'text_reader_test.dart' show writeEpub;

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
    writeArchive(work, 'Band 01.cbz', ['001.jpg', '002.jpg']);
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

    // Ein Manga wird gelesen, nicht abgespielt — auch auf dem Knopf.
    expect(find.text('Öffnen'), findsNothing);
    await tester.runAsync(() => tester.tap(find.text('Lesen')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(reader.failure, isNull);
    expect(reader.isOpen, isTrue);
    expect(engine.opened, isEmpty, reason: 'Der Player wurde angeworfen');
    // Geöffnet wird im Vollbild, also ohne Leiste — ein Tipp holt sie zurück.
    expect(reader.showsChrome, isFalse);
    // Die Lesefläche ändert dabei ihre Größe nicht. Als Spalte gebaut, tat
    // sie das — und ein Streifen, dessen Fenster sich ändert, sprang beim
    // Tippen in die Mitte an den Anfang des Kapitels.
    final before = tester.getSize(find.byType(ReaderScreen));
    reader.showChrome();
    await tester.pump();
    expect(tester.getSize(find.byType(ReaderScreen)), before);
    expect(find.textContaining('Seite 1 von 12'), findsWidgets);

    // Ein Doppeltipp holt heran; danach gehört jede Berührung der Seite und
    // nicht mehr dem Umblättern.
    expect(reader.isZoomed, isFalse);
    reader.toggleZoom();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(reader.isZoomed, isTrue);
    reader.toggleZoom();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(reader.isZoomed, isFalse);

    // Und ein zweites Öffnen holt nicht von selbst heran. Der Zähler stand
    // schon auf zwei; ein frisches Fenster hielt das für einen Doppeltipp.
    reader.close();
    await tester.pump();
    await tester.runAsync(() => scope.play(work));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();

    expect(reader.isZoomed, isFalse);
  });

  /// Aus dem Betrieb: bei Bild vier hinaus und wieder hinein, und der Leser
  /// stand auf Bild eins.
  testWidgets('der Stand überlebt das Schließen', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
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
    // Der Streifen ist der Fall, um den es geht: dort meldet die Liste, was
    // sie sieht, und diese Meldung überschrieb den gespeicherten Stand.
    await tester.runAsync(
      () => reader.updateProfile(
        const PublicationReaderProfile(
          layout: PublicationReaderLayout.continuousVertical,
        ),
      ),
    );
    await tester.runAsync(() => scope.play(work));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump();

    await tester.runAsync(() => reader.goToPage(3));
    await tester.pump();
    expect(reader.pageIndex, 3);

    reader.close();
    await tester.pump();
    await tester.runAsync(() => scope.play(work));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump();

    expect(reader.pageIndex, 3, reason: 'Der Stand wurde überschrieben');
  });

  testWidgets('eine Light Novel öffnet den Textleser', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final novelFolder = Directory('${root.path}/Light Novels/Glasmeer')
      ..createSync(recursive: true);
    writeEpub(novelFolder, 'Band 01.epub', ['Prolog', 'Erstes Kapitel']);

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
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    // Nichts an die Audio-Engine, und der Comic-Leser bleibt ebenfalls zu.
    expect(engine.opened, isEmpty);
    expect(reader.isOpen, isFalse);
    expect(scope.textReader.isOpen, isTrue);
    expect(scope.textReader.failure, isNull);
    expect(find.textContaining('Prolog'), findsWidgets);
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
