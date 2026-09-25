import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/protection.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Eigene Eigenschaften am Werk.
///
/// Angelegt werden sie in den Einstellungen, eingetragen am Werk. Geprüft wird
/// beides und vor allem, dass ein geschütztes Feld bei geschlossenem Schloss
/// nicht einmal mit seinem Namen dasteht.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-eigen-ui-');
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    File('${work.path}/01.cbz').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
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

  /// Legt eine Eigenschaft an, wie es die Einstellungsseite täte.
  Future<WorkPropertyDefinition> define(
    WidgetTester tester, {
    required String name,
    PropertyValueType type = PropertyValueType.text,
    bool protected = false,
  }) => tester
      .runAsync(
        () => library.library!.savePropertyDefinition(
          mediaKind: 'manga',
          name: name,
          valueType: type,
          protected: protected,
        ),
      )
      .then((value) {
        library.refresh();
        return value!;
      });

  Future<void> openProperties(WidgetTester tester) async {
    // Eigenschaften is intentionally the first and selected tab.
    await tester.pumpAndSettle();
  }

  /// Die Zeile liegt am Ende einer langen Liste — erst heranholen, dann
  /// antippen, sonst zielt der Tipp neben den Bildschirm.
  Future<void> openField(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.text(name));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('ein leeres Feld steht trotzdem da', (tester) async {
    // Ein Feld, das man erst sieht, wenn es gefüllt ist, füllt niemand.
    await pump(tester);
    await define(tester, name: 'Erscheinungsland');
    await tester.pumpAndSettle();
    await openProperties(tester);

    expect(find.text('EIGENE ANGABEN'), findsOneWidget);
    expect(find.text('Erscheinungsland'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('ein Wert lässt sich eintragen und wieder leeren', (
    tester,
  ) async {
    await pump(tester);
    final definition = await define(tester, name: 'Regal');
    await tester.pumpAndSettle();
    await openProperties(tester);

    await openField(tester, 'Regal');
    await tester.enterText(find.byType(TextField).last, 'Oben links');
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();

    expect(find.text('Oben links'), findsOneWidget);
    expect(
      library.library!
          .loadWorkProperties(library.works.first.id)[definition.id]
          ?.value,
      'Oben links',
    );

    await openField(tester, 'Regal');
    await tester.tap(find.text('Leeren'));
    await tester.pumpAndSettle();

    expect(
      library.library!.loadWorkProperties(library.works.first.id),
      isEmpty,
    );
  });

  testWidgets('eine Zahl, die keine ist, wird abgewiesen', (tester) async {
    await pump(tester);
    await define(tester, name: 'Seitenzahl', type: PropertyValueType.number);
    await tester.pumpAndSettle();
    await openProperties(tester);

    await openField(tester, 'Seitenzahl');
    await tester.enterText(find.byType(TextField).last, 'viele');
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();

    // Der Dialog bleibt offen und sagt, was fehlt — statt still nichts zu tun.
    expect(find.text('Das ist keine Zahl.'), findsOneWidget);
    expect(
      library.library!.loadWorkProperties(library.works.first.id),
      isEmpty,
    );
  });

  testWidgets(
    'ein geschütztes Feld erscheint bei geschlossenem Schloss nicht',
    (tester) async {
      // Schon der Name des Feldes verriete, worum es geht.
      final scope = await pump(tester);
      await define(tester, name: 'Harmlos');
      await define(tester, name: 'Verrät zu viel', protected: true);
      // Ohne eingeschalteten Schutzmodus ist nichts zu verbergen, und
      // `isUnlocked` ist dann zu Recht wahr.
      await scope.settings.setProtectionMode(ProtectionMode.hide);
      scope.protection.lock();
      await tester.pumpAndSettle();
      await openProperties(tester);

      expect(find.text('Harmlos'), findsOneWidget);
      expect(find.text('Verrät zu viel'), findsNothing);

      await scope.protection.unlockAuthenticatedSession();
      await tester.pumpAndSettle();

      expect(find.text('Verrät zu viel'), findsOneWidget);
    },
  );
}
