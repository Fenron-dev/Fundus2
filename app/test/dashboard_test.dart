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

/// Der Start.
///
/// „Was habe ich angefangen" gehört nach oben, und zwar so, dass man sieht,
/// wie weit — ein Poster allein beantwortet die Frage nicht.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-dash-');
    for (final title in ['Arrival', 'Dune']) {
      final folder = Directory('${root.path}/Filme/$title')
        ..createSync(recursive: true);
      await File('${folder.path}/$title.mkv').writeAsBytes(List.filled(64, 1));
    }
    final book = Directory('${root.path}/Hörbücher/Autor/Der Schacht')
      ..createSync(recursive: true);
    await File('${book.path}/01.mp3').writeAsBytes(List.filled(64, 1));

    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
    await library.open(root, createIfMissing: true);
    await library.scan();
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
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
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(const DashboardRoute());
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('was angefangen wurde, steht oben und lässt sich fortsetzen', (
    tester,
  ) async {
    final work = library.works.firstWhere((entry) => entry.title == 'Dune');
    library.library!.saveProgress(
      workId: work.id,
      fileId: library.library!.playbackTracks(work.id).single.fileId,
      position: const Duration(minutes: 20),
      duration: const Duration(minutes: 90),
      deviceId: 'test',
    );
    library.refreshWork(work.id);

    await pump(tester);

    expect(find.text('FORTSETZEN'), findsOneWidget);
    // Wie weit noch — das ist, was diese Reihe beantwortet. Der Vorschlag
    // oben kann dasselbe Werk zeigen und sagt es dann auch.
    expect(find.text('noch 1 Std 10 Min'), findsWidgets);

    // „Dune" steht mehrfach auf dem Schirm — im Vorschlag, in der Karte, in
    // der Reihe darunter. Gemeint ist die Karte, und die hat einen Namen.
    await tester.tap(find.byKey(ValueKey('fortsetzen-${work.id}')));
    await tester.pumpAndSettle();

    expect(player.work?.title, 'Dune', reason: 'Tippen setzt fort');
  });

  testWidgets('oben steht ein großer Vorschlag, auf dem Tablet zwei', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('VORSCHLAG FÜR HEUTE'), findsOneWidget);
    expect(find.text('ODER DAS HIER'), findsNothing);

    tester.view.physicalSize = const Size(1100, 1400);
    await tester.pumpAndSettle();

    expect(find.text('VORSCHLAG FÜR HEUTE'), findsOneWidget);
    expect(find.text('ODER DAS HIER'), findsOneWidget);
  });

  testWidgets('die Regale stehen mit ihren Zahlen da', (tester) async {
    await pump(tester);

    await tester.scrollUntilVisible(
      find.text('MEDIENTYPEN'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Filme'), findsWidgets);
    expect(find.text('Hörbücher'), findsWidgets);
    // Leere Regale stehen nicht herum.
    expect(find.text('TTRPG'), findsNothing);
  });

  testWidgets('ohne Fortsetzen keine leere Reihe', (tester) async {
    await pump(tester);

    expect(find.text('FORTSETZEN'), findsNothing);
    expect(find.text('ZULETZT HINZUGEFÜGT'), findsOneWidget);
  });
}
