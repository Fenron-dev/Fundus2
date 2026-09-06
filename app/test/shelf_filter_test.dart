import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/work_filter.dart';
import 'package:fundus_design/fundus_design.dart';

/// Die Leiste über dem Regal.
///
/// Sie gehört zum Regal, nicht zur Kopfzeile — sonst hat das Handy sie
/// nicht, und dort ist „was liegt offline hier?" die häufigste Frage.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-regal-');
    for (final title in ['Klingenwind', 'Sonnenlauf']) {
      final folder = Directory('${root.path}/Manga/$title')
        ..createSync(recursive: true);
      File('${folder.path}/001.cbz').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  /// Öffnet die Bibliothek und hängt einem Werk ein Genre an — so, wie es
  /// vom Abgleich käme. Läuft im echten Zeitfenster, weil beides die Platte
  /// anfasst.
  Future<void> fill(WidgetTester tester) => tester.runAsync(() async {
    await library.open(root, createIfMissing: true);
    await library.scan();
    final vault = library.library!;
    final first = vault.listWorks().firstWhere(
      (work) => work.title == 'Klingenwind',
    );
    await vault.updateWorkMetadata(
      workId: first.id,
      title: first.title,
      authors: const ['Unbekannt'],
      genres: const ['Shōnen'],
    );
    library.refresh();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester, Size size) async {
    await fill(tester);
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
    scope.navigation.reset(const LibraryRoute());
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('auch auf dem Handy stehen Herkunft, Genre und Ordnung da', (
    tester,
  ) async {
    await pump(tester, const Size(420, 900));

    expect(find.text('Herkunft'), findsOneWidget);
    expect(find.text('Genre'), findsOneWidget);
    // Der Rest der Leiste liegt rechts daneben und wird herangeschoben —
    // eine liegende Liste baut nur, was zu sehen ist.
    await tester.drag(find.text('Herkunft'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(find.text('Favoriten'), findsOneWidget);
  });

  testWidgets('ein Genre lässt sich anhaken und wieder wegnehmen', (
    tester,
  ) async {
    final scope = await pump(tester, const Size(900, 1000));

    await tester.tap(find.text('Genre'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shōnen').last);
    await tester.pumpAndSettle();

    expect(scope.filter.tags, {'Shōnen'});
    // Und das Regal zeigt nur noch, was so ausgezeichnet ist.
    expect(scope.filter.apply(library.works).map((work) => work.title), [
      'Klingenwind',
    ]);

    // Der gewählte Filter steht als eigener Chip daneben: ein Tipp darauf
    // nimmt ihn wieder weg. Er liegt rechts, also erst heranschieben.
    await tester.drag(find.text('Herkunft'), const Offset(-320, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'Shōnen'));
    await tester.pumpAndSettle();
    expect(scope.filter.tags, isEmpty);
  });

  testWidgets('ein Genre ist auch ein Schlagwort', (tester) async {
    await fill(tester);
    await tester.runAsync(() async {
      final vault = library.library!;
      final second = vault.listWorks().firstWhere(
        (work) => work.title == 'Sonnenlauf',
      );
      await vault.replaceWorkTags(second.id, const ['Webtoon']);
      library.refresh();
    });

    const filter = WorkFilter(tags: {'Webtoon'});
    expect(filter.apply(library.works).map((work) => work.title), [
      'Sonnenlauf',
    ]);
  });
}
