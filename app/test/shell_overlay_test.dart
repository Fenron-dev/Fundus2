import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'reader_test.dart' show FakePageSource, writeArchive;

/// Was verdeckt ist, wird nicht gezeichnet.
///
/// Ein Stack malt jede Ebene. Unter dem laufenden Film wurden das Kachelgitter
/// mit allen Covern und die Navigationsspalte weiter vermessen und gezeichnet
/// — für ein Fenster, das niemand sehen konnte. Das war ein guter Teil dessen,
/// was sich wie „laggy" anfühlte.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late ReaderController reader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-overlay-');
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    writeArchive(work, 'Band 01.cbz', ['001.jpg', '002.jpg']);
    library = LibraryController();
    settings = AppSettings.inMemory();
    reader = ReaderController(
      openSource: (path, name) => FakePageSource(name, 12),
    );
  });

  tearDown(() async {
    reader.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('die Bibliothek liegt hinter dem Leser still', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
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
    scope.navigation.reset(const LibraryRoute());
    await tester.pumpAndSettle();
    // „Alle Werke" steht in der Navigationsspalte — die gibt es nur in der
    // Schale, nicht im Leser.
    expect(find.text('Alle Werke'), findsWidgets);

    await tester.runAsync(
      () => reader.open(library.library!, library.works.single),
    );
    await tester.pumpAndSettle();

    expect(reader.isOpen, isTrue);
    // Die Bibliothek ist noch da — aber ausgeblendet, also weder vermessen
    // noch gezeichnet.
    expect(find.text('Alle Werke'), findsNothing);
    expect(
      find.text('Alle Werke', skipOffstage: false),
      findsWidgets,
      reason: 'sie bleibt am Leben, damit die Scrollposition erhalten bleibt',
    );
    // Und der Leser selbst füllt das Fenster, statt auf null zu schrumpfen.
    expect(tester.getSize(find.byType(FundusShell)).width, 1440);
    expect(find.textContaining('Seite 1 von 12'), findsWidgets);

    reader.close();
    await tester.pumpAndSettle();
    expect(find.text('Alle Werke'), findsWidgets);
  });
}
