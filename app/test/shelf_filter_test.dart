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
/// Öffnet das Medienart-Menü.
///
/// Über die Schaltfläche, nicht über den Chip: der ist mit `onSelected: null`
/// abgeschaltet und dient nur als Beschriftung dessen, was gerade gilt.
Future<void> openMediaTypeMenu(WidgetTester tester) async {
  // Über den Tooltip, nicht über die Beschriftung: sobald eine Art gewählt
  // ist, trägt der Chip deren Namen statt „Medienart".
  await tester.tap(
    find.byTooltip('Nach Medienart filtern'),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
}

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
    // eine liegende Liste baut nur, was zu sehen ist. Geschoben wird bis der
    // Eintrag da ist, nicht um eine feste Strecke: die Leiste bekommt mit
    // jedem neuen Sieb einen Chip mehr, und eine geratene Strecke wird dann
    // still zu kurz.
    // Geschoben wird, bis der Eintrag da ist — nicht um eine geratene
    // Strecke: die Leiste bekommt mit jedem neuen Sieb einen Chip mehr, und
    // eine feste Strecke wird dann still zu kurz.
    // Gezogen wird von einer festen Stelle in der Leiste: der Chip, an dem man
    // anfasst, wandert beim Schieben selbst aus dem Bild.
    final griff = tester.getCenter(find.text('Herkunft'));
    for (var tries = 0; tries < 12; tries++) {
      if (find.text('Favoriten').evaluate().isNotEmpty) break;
      await tester.dragFrom(griff, const Offset(-120, 0));
      await tester.pumpAndSettle();
    }
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
    await tester.drag(find.text('Herkunft'), const Offset(-480, 0));
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

  testWidgets('„Alle Werke" bekommt einen Medienart-Filter', (tester) async {
    // Die Ansicht, in der am meisten steht, war die einzige ohne dieses Sieb:
    // die Medienart ließ sich nur über die Seitenleiste wählen.
    final scope = await pump(tester, const Size(1440, 900));
    expect(scope.filter.mediaTypeId, isNull);
    expect(find.text('Medienart'), findsOneWidget);

    await openMediaTypeMenu(tester);
    expect(find.text('Alle Medienarten'), findsOneWidget);

    await tester.tap(find.text('Manga & Comics').last);
    await tester.pumpAndSettle();
    expect(scope.filter.mediaTypeId, 'manga');

    // Und wieder zurück. Geöffnet wird über die Schaltfläche: der Chip selbst
    // ist abgeschaltet und dient nur als Beschriftung.
    await openMediaTypeMenu(tester);
    await tester.tap(find.text('Alle Medienarten'));
    await tester.pumpAndSettle();
    expect(scope.filter.mediaTypeId, isNull);
  });

  testWidgets('in einem Medienart-Regal steht der Filter nicht', (
    tester,
  ) async {
    // Dort gibt die Route die Art vor; ein Sieb daneben, das sie überschreibt,
    // wäre zwei Wahrheiten an einer Stelle.
    final scope = await pump(tester, const Size(1440, 900));
    scope.openMediaType('manga');
    await tester.pumpAndSettle();

    expect(find.text('Medienart'), findsNothing);
    expect(find.text('Herkunft'), findsOneWidget);
  });

  testWidgets('leere Medienarten stehen nicht zur Wahl', (tester) async {
    await pump(tester, const Size(1440, 900));
    await openMediaTypeMenu(tester);

    expect(find.text('Manga & Comics'), findsWidgets);
    expect(find.text('Hörbücher'), findsNothing);
    expect(find.text('Serien'), findsNothing);
  });
}
