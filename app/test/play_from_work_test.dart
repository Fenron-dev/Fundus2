import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// The button in the work detail is the only way into playback, so it gets a
/// test of its own: it must be enabled, it must reach the player, and the
/// mini player must appear. It shipped once disabled, which looked exactly
/// like a broken player from the outside.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-play-');
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
    library = LibraryController();
    settings = AppSettings.inMemory();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('Öffnen im Werk startet die Wiedergabe', (tester) async {
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

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Öffnen'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNotNull, reason: 'Der Knopf ist abgeschaltet');

    await tester.runAsync(() => tester.tap(find.text('Öffnen')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(player.failure, isNull);
    expect(engine.opened, hasLength(1));
    expect(engine.playing, isTrue);
    // Und der Mini-Player steht da.
    expect(find.text('01 - Anfang.mp3'), findsWidgets);
  });
}
