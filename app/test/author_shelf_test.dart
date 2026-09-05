import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus_design/fundus_design.dart';

/// Der Weg Urheber → Reihe → Buch.
///
/// „Nach Urheber" führte bisher auf eine flache Wand aller Bände, die jemand
/// je geschrieben hat: die sieben Teile der einen Reihe zwischen den drei der
/// anderen, und nichts sagte, welcher wozu gehört.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  Future<void> book(String path) async {
    final directory = Directory('${root.path}/Hörbücher/$path')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/01 - Kapitel.mp3',
    ).writeAsBytes(List.filled(64, 1));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-author-');
    await book('Karl May/Winnetou/01 - Winnetou I');
    await book('Karl May/Winnetou/02 - Winnetou II');
    await book('Karl May/Der Schatz im Silbersee');
    await book('Franz Kafka/Die Verwandlung');
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('vom Urheber über die Reihe zum Band', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });
    expect(library.works, hasLength(4));

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

    scope.openMediaType(MediaTypes.audiobook.id);
    await tester.pumpAndSettle();

    // Erst die Urheber.
    await tester.tap(find.text(GroupingMode.author.label));
    await tester.pumpAndSettle();
    expect(find.text('Karl May'), findsOneWidget);
    expect(find.text('Franz Kafka'), findsOneWidget);
    expect(
      find.text('Winnetou I'),
      findsNothing,
      reason: 'die Bände gehören eine Ebene tiefer',
    );

    // Dann seine Reihen, und was einzeln steht.
    await tester.tap(find.text('Karl May'));
    await tester.pumpAndSettle();
    expect(find.text('Winnetou'), findsOneWidget);
    expect(find.text('Einzeln'), findsOneWidget);
    expect(find.text('Der Schatz im Silbersee'), findsWidgets);
    expect(find.text('Die Verwandlung'), findsNothing);

    // Und dann die Bände, in der Reihenfolge der Reihe.
    await tester.tap(find.text('Winnetou'));
    await tester.pumpAndSettle();
    expect(find.text('Winnetou I'), findsWidgets);
    expect(find.text('Winnetou II'), findsWidgets);

    // Der Pfad führt beide Schritte zurück.
    expect(find.text('Karl May'), findsWidgets);
  });
}
