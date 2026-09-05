import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/text_reader_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Ein Buch fängt dort wieder an, wo es zugeklappt wurde.
///
/// Der Stand wurde gespeichert und beim Öffnen auch gelesen — nur ging die
/// Ansicht nie dorthin: eine Liste baut nur, was in der Nähe des Bildschirms
/// ist, der gesuchte Absatz hatte also noch kein Widget, der Sprung gab still
/// auf, und die erste Scroll-Meldung überschrieb den Stand mit „Absatz 0".
final class LongTextSource implements TextSource {
  LongTextSource(this.name);

  @override
  final String name;

  @override
  Future<List<TextChapter>> chapters() async => [
    TextChapter(
      id: 'kapitel-1',
      title: 'Erstes Kapitel',
      document: ReflowDocument.parse(
        List.generate(
          400,
          (index) =>
              'Absatz $index. Hier steht genug Text, dass eine Liste ihn '
              'nicht auf einmal baut, sondern erst beim Scrollen.',
        ).join('\n\n'),
        format: ReflowSourceFormat.plainText,
      ),
    ),
  ];
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late TextReaderController reader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-resume-');
    final work = Directory('${root.path}/Light Novels/Glasmeer')
      ..createSync(recursive: true);
    await File('${work.path}/Band 01.epub').writeAsBytes(List.filled(64, 1));
    library = LibraryController();
    settings = AppSettings.inMemory();
    reader = TextReaderController(
      openSource: (path, name) => LongTextSource(name),
    );
  });

  tearDown(() async {
    reader.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('der Stand überlebt das Schließen und Wiederöffnen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    final work = library.works.single;
    late FundusScopeState scope;

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          textReader: reader,
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

    await tester.runAsync(() => reader.open(library.library!, work));
    await tester.pumpAndSettle();
    expect(reader.isOpen, isTrue);

    // Weit genug unten, dass der Absatz beim Öffnen garantiert noch nicht
    // gebaut ist — genau der Fall, in dem der Sprung vorher aufgab.
    reader.reportPosition(180, 0);
    reader.saveProgress();
    reader.close();
    await tester.pumpAndSettle();

    final stored = library.library!.loadProgress(work.id);
    expect(stored, isNotNull);

    // Dasselbe Buch noch einmal öffnen, im selben Leser — genau das, was
    // jemand tut, der weiterlesen will.
    await tester.runAsync(() => reader.open(library.library!, work));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(reader.paragraphIndex, 180, reason: 'das Modell weiß es');
    expect(
      find.textContaining('Absatz 180.'),
      findsOneWidget,
      reason: 'und die Ansicht steht auch dort',
    );

    // Und der Stand darf von der Ansicht nicht wieder überschrieben werden.
    reader.saveProgress();
    expect(
      library.library!.loadProgress(work.id)!.position.scrollOffset,
      isNotNull,
    );
    expect(reader.paragraphIndex, greaterThan(150));
  });
}
