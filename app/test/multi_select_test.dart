import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus_design/fundus_design.dart';

/// Mehrere Werke auf einmal.
///
/// Zwölf Bände einer Reihe haben denselben Urheber und denselben Verlag;
/// sie einzeln einzutragen ist Arbeit ohne Erkenntnis.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-auswahl-');
    for (final band in ['Band 1', 'Band 2', 'Band 3']) {
      final folder = Directory('${root.path}/Hörbücher/Königsmörder/$band')
        ..createSync(recursive: true);
      File('${folder.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    await library.library?.flushSidecarWrites();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
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
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(const LibraryRoute());
    scope.setFilter(scope.filter.copyWith(grouping: GroupingMode.table));
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('langes Drücken beginnt die Auswahl', (tester) async {
    await pump(tester);

    await tester.longPress(find.text('Band 1').first);
    await tester.pumpAndSettle();

    expect(find.text('1 ausgewählt'), findsOneWidget);

    // Ein zweiter Tipp wählt dazu, statt zu öffnen.
    await tester.tap(find.text('Band 2').first);
    await tester.pumpAndSettle();
    expect(find.text('2 ausgewählt'), findsOneWidget);
  });

  testWidgets('gemeinsam bearbeiten schreibt auf alle', (tester) async {
    final scope = await pump(tester);

    await tester.longPress(find.text('Band 1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle'));
    await tester.pumpAndSettle();
    expect(find.text('3 ausgewählt'), findsOneWidget);

    await tester.tap(find.text('Gemeinsam bearbeiten'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Urheber'),
      'Patrick Rothfuss',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Verlag'),
      'Random House Audio',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Auf 3 Werke schreiben'));
    });
    // Portable writes are real I/O and can be queued behind a UI-originated
    // profile write. Drive both clocks until the completed dialog disappears,
    // not a guessed 600 ms that races on loaded CI runners.
    for (var attempt = 0; attempt < 150; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (find.byType(AlertDialog).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final works = scope.library.library!.listWorks();
    expect(works, hasLength(3));
    for (final work in works) {
      expect(work.author, 'Patrick Rothfuss');
      expect(work.publisher, 'Random House Audio');
      // Der Titel bleibt der des einzelnen Bandes.
      expect(work.title, isNot('Patrick Rothfuss'));
    }
  });
}
