import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
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
    final page = find.byType(Scrollable).first;
    for (final heading in const [
      'Zuletzt hinzugefügt',
      'Zufällig entdecken',
      'Alle Filme',
    ]) {
      await tester.scrollUntilVisible(
        find.text(heading),
        400,
        scrollable: page,
      );
      expect(find.text(heading), findsOneWidget);
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

  test('nur Filme und Serien bekommen eine Bühne', () {
    expect(StageScreen.suits(MediaTypes.movies), isTrue);
    expect(StageScreen.suits(MediaTypes.series), isTrue);
    expect(StageScreen.suits(MediaTypes.audiobook), isFalse);
    expect(StageScreen.suits(null), isFalse);
  });
}
