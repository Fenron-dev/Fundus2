import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/features/library/shelf_sections.dart';
import 'package:fundus/features/library/stage_screen.dart';
import 'package:fundus/features/library/work_poster.dart';
import 'package:fundus_design/fundus_design.dart';

/// Die Bühne für Filme und Serien.
///
/// Ein Gitter aus zweihundert gleich großen Miniaturbildern ist eine
/// Dateiliste. Was eine Bibliothek zum Öffnen wert macht, ist, dass sie einem
/// etwas hinstellt — und dass das, was man angefangen hat, in Reichweite ist.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-stage-');
    for (final title in ['Arrival', 'Blade Runner', 'Coherence', 'Dune']) {
      final folder = Directory('${root.path}/Filme/$title')
        ..createSync(recursive: true);
      await File('${folder.path}/$title.mkv').writeAsBytes(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root, createIfMissing: true);
    await library.scan();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.openMediaType(MediaTypes.movies.id);
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('Filme führen mit einem Vorschlag und Reihen', (tester) async {
    await pump(tester, const Size(420, 900));

    expect(find.byType(StageScreen), findsOneWidget);
    expect(find.text('Vorschlag für heute'.toUpperCase()), findsOneWidget);
    // Und der Vorschlag lässt sich starten, ohne den Umweg über die Details.
    expect(find.text('Abspielen'), findsOneWidget);

    // Der Rest steht darunter — eine Bühne baut nur, was zu sehen ist.
    // Die Bühne selbst, nicht die Filterleiste darüber: die ist auch eine
    // Liste, nur eine liegende.
    final page = find
        .descendant(
          of: find.byType(StageScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final heading in const [
      'Zuletzt hinzugefügt',
      'Zufällig entdecken',
      'Alle Filme',
    ]) {
      // Auf der Bühne gesucht, nicht in der Filterleiste: „Zuletzt
      // hinzugefügt" steht dort auch, als Sortierung.
      final onStage = find.descendant(
        of: find.byType(StageScreen),
        matching: find.text(heading),
      );
      await tester.scrollUntilVisible(onStage, 400, scrollable: page);
      expect(onStage, findsOneWidget);
    }
  });

  testWidgets('gesucht wird in der Liste, nicht auf der Bühne', (tester) async {
    final scope = await pump(tester, const Size(420, 900));

    scope.setFilter(scope.filter.copyWith(text: 'Dune'));
    await tester.pumpAndSettle();

    expect(
      find.byType(StageScreen),
      findsNothing,
      reason: 'ein Vorschlag steht einer Antwort im Weg',
    );
  });

  testWidgets('ein Tablet zeigt mehr Spalten als ein Telefon', (tester) async {
    await pump(tester, const Size(420, 900));
    final onPhone = tester.widgetList<WorkPoster>(find.byType(WorkPoster));
    final phoneWidth = onPhone.first.width;

    await pump(tester, const Size(1000, 1200));
    final onTablet = tester.widgetList<WorkPoster>(find.byType(WorkPoster));

    expect(onTablet.first.width, greaterThan(phoneWidth));
  });

  /// Die Überschrift einer Reihe ist ein Versprechen: es gibt mehr davon als
  /// die zwanzig, die nebeneinander passen. Sie führt auf die Seite dazu.
  testWidgets('die Überschrift einer Reihe führt auf ihre Seite', (
    tester,
  ) async {
    final scope = await pump(tester, const Size(1000, 1400));

    final onStage = find.descendant(
      of: find.byType(StageScreen),
      matching: find.text('Zuletzt hinzugefügt'),
    );
    final page = find
        .descendant(
          of: find.byType(StageScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(onStage, 400, scrollable: page);
    await tester.tap(onStage);
    await tester.pumpAndSettle();

    final route = scope.navigation.current;
    expect(route, isA<LibraryRoute>());
    expect((route as LibraryRoute).section, ShelfSection.recent);
    expect((route).mediaTypeId, MediaTypes.movies.id);
    // Dort steht die Reihe ganz, und keine Bühne mehr davor.
    expect(find.byType(StageScreen), findsNothing);
    expect(find.textContaining('Zuletzt hinzugefügt · Filme'), findsWidgets);
  });

  /// „Was jetzt?" ist bei Hörbüchern dieselbe Frage wie bei Filmen; eine Wand
  /// gleicher Kacheln ist überall ein Dateilisting.
  test('jedes Regal bekommt eine Bühne, die Gesamtansicht nicht', () {
    expect(StageScreen.suits(MediaTypes.movies), isTrue);
    expect(StageScreen.suits(MediaTypes.series), isTrue);
    expect(StageScreen.suits(MediaTypes.audiobook), isTrue);
    expect(StageScreen.suits(MediaTypes.manga), isTrue);
    // Ohne Medientyp steht da alles, was es gibt — dafür ist die Bühne nicht.
    expect(StageScreen.suits(null), isFalse);
  });
}
