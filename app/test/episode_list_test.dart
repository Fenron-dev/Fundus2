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

/// Die Folgenliste eines Werks.
///
/// Sie war eine Inventarliste: Nummern, Namen, Längen — und kein Weg, Folge
/// sieben zu starten oder zu sagen, dass Folge drei gesehen ist.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-episodes-');
    final series = Directory('${root.path}/Serien/Kaltes Orbit')
      ..createSync(recursive: true);
    for (final name in [
      'S01E01 - Signalabbruch',
      'S01E02 - Bergungsrecht',
      'S02E01 - Rückkanal',
      'S02E02 - Zwölf Stunden vorher',
    ]) {
      File('${series.path}/$name.mkv').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });

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
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('eine Staffel wird gewählt, nicht alles gezeigt', (tester) async {
    await pump(tester);

    // Staffel 1 steht vorne, und nur ihre Folgen stehen darunter.
    expect(find.text('Staffel 1'), findsOneWidget);
    expect(find.textContaining('Signalabbruch'), findsOneWidget);
    expect(find.textContaining('Rückkanal'), findsNothing);

    await tester.tap(find.text('Staffel 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Staffel 2').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Rückkanal'), findsOneWidget);
    expect(find.textContaining('Signalabbruch'), findsNothing);
  });

  testWidgets('eine Folge lässt sich einzeln starten', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.textContaining('Bergungsrecht'));
      // Das Öffnen läuft gegen die echte Platte; hier wird es abgewartet.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    // Nicht Folge eins: die angetippte.
    expect(player.currentSource?.title, contains('Bergungsrecht'));
  });

  testWidgets('eine Folge lässt sich als gesehen abhaken', (tester) async {
    await pump(tester);

    expect(find.text('gesehen'), findsNothing);
    await tester.tap(find.byTooltip('Als gesehen markieren').first);
    await tester.pumpAndSettle();

    expect(find.text('gesehen'), findsOneWidget);
    // Und es bleibt: die Bibliothek weiß es, nicht nur der Bildschirm.
    expect(
      library.library!.finishedFiles(library.works.first.id),
      hasLength(1),
    );

    await tester.tap(find.byTooltip('Als ungesehen markieren'));
    await tester.pumpAndSettle();
    expect(library.library!.finishedFiles(library.works.first.id), isEmpty);
  });
}
