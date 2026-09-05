import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_design/fundus_design.dart';

/// The detail page on a phone.
///
/// The screenshots that prompted this showed the head filling the whole
/// screen: the title squeezed into a narrow column beside the cover, the tab
/// headings just visible at the bottom, and nothing under them reachable.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-detail-');
    final work = Directory(
      '${root.path}/Hörbücher/Karl May/'
      'Der Schatz im Silbersee und die lange Nacht danach',
    )..createSync(recursive: true);
    for (var index = 1; index <= 8; index++) {
      File(
        '${work.path}/${index.toString().padLeft(2, '0')} - Kapitel $index.mp3',
      ).writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pumpPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
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
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    return scope;
  }

  testWidgets('der Inhalt unter den Reitern ist erreichbar', (tester) async {
    await pumpPhone(tester);

    // Der Kopf steht oben, die Dateien liegen darunter — und sie lassen sich
    // erreichen, statt hinter dem Bildschirmrand zu bleiben.
    expect(find.textContaining('Kapitel 1'), findsWidgets);
    await tester.drag(find.byType(TabBarView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Kapitel 1').hitTestable(),
      findsWidgets,
      reason: 'die Dateiliste muss anfassbar sein, nicht nur gebaut',
    );
    // Und die Reiterleiste bleibt oben stehen, während der Kopf weggeht.
    expect(find.byType(TabBar).hitTestable(), findsOneWidget);
    expect(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.data == library.works.first.title &&
                widget.style?.fontSize == FundusStageSize.handset.titleSize,
          )
          .hitTestable(),
      findsNothing,
      reason: 'der Kopf scrollt weg, statt den Bildschirm zu besetzen',
    );
  });

  testWidgets('ein Breitbild wird im Kopf gezeigt, nicht das Cover', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await library.library!.cacheBackdrop(
        workId: library.works.first.id,
        bytes: Uint8List.fromList(List.filled(64, 5)),
      );
      library.refreshWork(library.works.first.id);
    });
    await pumpPhone(tester);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is FileImage &&
            (widget.image as FileImage).file.path.endsWith('.backdrop.jpg'),
      ),
      findsWidgets,
      reason: 'wo ein Breitbild liegt, füllt es den Kopf',
    );
  });

  testWidgets('ein langer Titel bekommt die ganze Breite', (tester) async {
    await pumpPhone(tester);

    // Der große Titel im Kopf, nicht der kleine in der Pfadleiste.
    final title = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == library.works.first.title &&
          widget.style?.fontSize == FundusStageSize.handset.titleSize,
    );
    expect(title, findsOneWidget);
    final width = tester.getSize(title).width;
    expect(
      width,
      greaterThan(300),
      reason:
          'auf dem Handy steht der Titel unter dem Cover und nicht in einer '
          'schmalen Spalte daneben',
    );
  });
}
