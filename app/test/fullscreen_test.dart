import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fullscreen.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show FakePageSource, writeArchive;

/// Fullscreen belongs to every player, not just the video one: reading a
/// manga with the shell around it is the case the user named first.
final class FakeFullscreen implements FullscreenMode {
  int entered = 0;
  int exited = 0;

  @override
  Future<void> enter() async => entered++;

  @override
  Future<void> exit() async => exited++;
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late FakeEngine engine;
  late PlaybackController player;
  late ReaderController reader;
  late FakeFullscreen window;
  late FullscreenController fullscreen;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-fullscreen-');
    library = LibraryController();
    settings = AppSettings.inMemory();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
    reader = ReaderController(
      openSource: (path, name) => FakePageSource(name, 12),
    );
    window = FakeFullscreen();
    fullscreen = FullscreenController(mode: window);
  });

  tearDown(() async {
    fullscreen.dispose();
    reader.dispose();
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          reader: reader,
          fullscreen: fullscreen,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    return scope;
  }

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  testWidgets('der Leser kann ins Vollbild und wieder heraus', (tester) async {
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    writeArchive(work, 'Band 01.cbz', ['001.jpg']);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    final scope = await pumpShell(tester);
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await settle(tester);
    await tester.runAsync(() => scope.play(library.works.first));
    await settle(tester);

    expect(reader.isOpen, isTrue);
    await tester.tap(find.byTooltip('Vollbild'));
    await settle(tester);

    expect(fullscreen.isActive, isTrue);
    expect(window.entered, 1);
    // Vollbild heißt Vollbild: die Leiste geht mit.
    expect(reader.showsChrome, isFalse);
    expect(find.byTooltip('Vollbild beenden'), findsNothing);

    // Ein Tipp in die Mitte holt sie zurück.
    reader.showChrome();
    await settle(tester);
    await tester.tap(find.byTooltip('Vollbild beenden'));
    await settle(tester);

    expect(fullscreen.isActive, isFalse);
    expect(window.exited, 1);
    expect(reader.showsChrome, isTrue);
  });

  testWidgets('der Player kann ins Vollbild', (tester) async {
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${work.path}/01 - Anfang.mp3').writeAsBytesSync(List.filled(64, 1));

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    final scope = await pumpShell(tester);
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await settle(tester);
    await tester.runAsync(() => scope.play(library.works.first));
    await settle(tester);

    await tester.tap(find.byTooltip('Vollbild'));
    await settle(tester);

    expect(fullscreen.isActive, isTrue);
    expect(window.entered, 1);
  });

  testWidgets('das Schließen lässt das Fenster nicht im Vollbild stehen', (
    tester,
  ) async {
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    writeArchive(work, 'Band 01.cbz', ['001.jpg']);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    final scope = await pumpShell(tester);
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await settle(tester);
    await tester.runAsync(() => scope.play(library.works.first));
    await settle(tester);

    await tester.tap(find.byTooltip('Vollbild'));
    await settle(tester);
    // Die Leiste ist im Vollbild weg; sie muss erst zurückgeholt werden.
    reader.showChrome();
    await settle(tester);
    await tester.tap(find.byTooltip('Schließen'));
    await settle(tester);

    expect(reader.isOpen, isFalse);
    expect(fullscreen.isActive, isFalse, reason: 'Das Fenster bleibt gefangen');
    expect(window.exited, 1);
  });
}
