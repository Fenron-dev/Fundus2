import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/settings/settings_catalog.dart';
import 'package:fundus/features/settings/settings_screen.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Every area in the catalogue leads somewhere.
///
/// The overview lists the settings areas; for a while several of them led to
/// a page that only explained that the page did not exist yet. This walks the
/// catalogue and opens each one, because a list that promises a page nobody
/// wrote is worse than a shorter list.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-settings-');
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    final vault = await FundusLibrary.create(root);
    await for (final _ in vault.index()) {}
    vault.close();

    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root);
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpArea(WidgetTester tester, String category) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          scanner: const NoPairingScanner(),
          child: Scaffold(body: SettingsScreen(category: category)),
        ),
      ),
    );
    // Zwei Seiten lesen beim Aufbau von der Platte. In der Scheinzeit von
    // `testWidgets` wird daraus nie etwas, also läuft das echte Warten hier
    // und danach wird nur noch gezeichnet — `pumpAndSettle` würde auf einen
    // Fortschrittsbalken warten, der sich für immer dreht.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final area in SettingsAreas.all) {
    testWidgets('„${area.label}" ist eine Seite, kein Versprechen', (
      tester,
    ) async {
      await pumpArea(tester, area.key);

      expect(find.text(area.label), findsWidgets);
      // Der alte Platzhalter erklärte, dass es die Seite noch nicht gibt.
      expect(find.textContaining('kommen mit ihr'), findsNothing);
      expect(find.textContaining('gibt es nicht'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ein Bereich, den es nicht gibt, sagt das', (tester) async {
    await pumpArea(tester, 'gibt-es-nicht');

    expect(find.textContaining('gibt es nicht'), findsOneWidget);
  });
}
