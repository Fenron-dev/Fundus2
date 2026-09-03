import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/library/work_tile.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// The shell on a phone.
///
/// The wide layout keeps the navigation column standing; a phone has no room
/// for it, and everything it carried — the media types, the settings areas —
/// went with it. What is tried here is that none of it became unreachable.
void main() {
  /// A small phone in logical pixels. Narrower than most, on purpose.
  const phone = Size(360, 760);

  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-compact-');
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pumpPhone(
    WidgetTester tester, {
    FundusRoute route = const DashboardRoute(),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: MaterialApp(
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
      ),
    );
    scope.navigation.reset(route);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    return scope;
  }

  Future<void> fillVault(WidgetTester tester) async {
    await tester.runAsync(() async {
      final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
      await work.create(recursive: true);
      for (var index = 1; index <= 6; index++) {
        await File(
          '${work.path}/0$index - Kapitel.mp3',
        ).writeAsBytes(List.filled(64, 1));
      }
      final vault = await FundusLibrary.create(root);
      await for (final _ in vault.index()) {}
      vault.close();
      await library.open(root);
    });
  }

  testWidgets('die Seitenleiste kommt von der Seite herein', (tester) async {
    await tester.runAsync(() => library.open(root, createIfMissing: true));
    await pumpPhone(tester);

    // Ohne sie ist auf dem Telefon nichts davon erreichbar.
    expect(find.text('Alle Werke'), findsNothing);

    await tester.tap(find.byTooltip('Navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Alle Werke'), findsOneWidget);
    expect(find.text('Hörbücher'), findsOneWidget);

    // Und ein Tippen darin führt weiter und schließt sie hinter sich.
    await tester.tap(find.text('Hörbücher'));
    await tester.pumpAndSettle();
    expect(find.text('Alle Werke'), findsNothing);
  });

  testWidgets('„Mehr" zeigt alle Bereiche, nicht nur einen', (tester) async {
    await tester.runAsync(() => library.open(root, createIfMissing: true));
    final scope = await pumpPhone(tester, route: const SettingsRoute());

    // Vorher landete das Telefon in „Darstellung" und kam da nicht mehr raus.
    expect(find.text('Einstellungen'), findsWidgets);
    expect(find.text('Darstellung'), findsOneWidget);
    expect(find.text('Wiedergabe'), findsOneWidget);

    // Die weiter unten liegenden Bereiche sind erreichbar, nicht nur gelistet.
    await tester.dragUntilVisible(
      find.text('Geräte & Abgleich'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Geräte & Abgleich'));
    await tester.pumpAndSettle();
    expect(
      (scope.navigation.current as SettingsRoute).category,
      'synchronisation',
    );
    expect(find.text('Dieses Gerät'), findsOneWidget);

    // Und zurück geht auch.
    await tester.tap(find.byTooltip('Zurück'));
    await tester.pumpAndSettle();
    expect(find.text('Darstellung'), findsOneWidget);
  });

  testWidgets('die Kacheln passen auf einen schmalen Bildschirm', (
    tester,
  ) async {
    await fillVault(tester);
    await pumpPhone(tester, route: const LibraryRoute());

    expect(find.text('Der Schacht'), findsOneWidget);
    // Ein abgeschnittenes Kachel-Innenleben meldet sich als Überlauf.
    expect(tester.takeException(), isNull);
  });

  testWidgets('auch bei großer Systemschrift', (tester) async {
    await fillVault(tester);
    await pumpPhone(tester, route: const LibraryRoute(), textScale: 1.6);

    expect(tester.takeException(), isNull);
  });

  test('die Kachelhöhe wächst mit Spaltenbreite und Schriftgröße', () {
    double extent(double width, double scale) => workTileExtent(
      tileWidth: width,
      density: FundusDensity.comfortable,
      textScaler: TextScaler.linear(scale),
    );

    // Das Cover ist 2:3, also bestimmt die Breite den Löwenanteil.
    expect(extent(160, 1), greaterThan(extent(120, 1)));
    // Und größere Schrift braucht mehr Platz, nicht denselben.
    expect(extent(160, 1.6), greaterThan(extent(160, 1)));
    // Vier Textzeilen plus Cover — nie weniger als das Cover selbst.
    expect(extent(160, 1), greaterThan((160 - 24) * 3 / 2));
  });
}
