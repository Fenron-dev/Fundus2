import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_design/fundus_design.dart';

/// Suchen auf dem Telefon.
///
/// Das Suchfeld saß in der Desktop-Kopfzeile, die es in der kompakten Schale
/// nicht gibt — auf dem Handy war die Bibliothek damit gar nicht durchsuchbar.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-search-');
    for (final title in ['Arrival', 'Dune', 'Solaris']) {
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

  testWidgets('vom Telefon aus lässt sich suchen', (tester) async {
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

    // Die Suche steht in der unteren Leiste.
    await tester.tap(find.text('Suche'));
    await tester.pumpAndSettle();
    expect(find.text('Titel, Urheber, Reihe …'), findsOneWidget);
    expect(find.text('Durchsuchen'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Dune');
    await tester.pumpAndSettle();

    expect(find.text('Ein Treffer'), findsOneWidget);
    // Zweimal: im Feld und als Treffer.
    expect(find.text('Dune'), findsNWidgets(2));
    expect(find.text('Solaris'), findsNothing);
    expect(find.text('Arrival'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Gibtsnicht');
    await tester.pumpAndSettle();

    expect(find.text('Nichts gefunden'), findsOneWidget);
  });
}
