import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_design/fundus_design.dart';

/// Wide enough for the two-column shell; the compact layout is a second state
/// of the same navigation, not a second app.
const _desktop = Size(1440, 900);

/// Opens a vault from inside a widget test.
///
/// `testWidgets` runs in a fake-async zone where real file and database I/O
/// never completes, so anything touching the disk has to go through
/// [WidgetTester.runAsync].
/// Lets pending real file and database work finish.
///
/// The fake-async zone of `testWidgets` does not run the real event loop, so
/// anything the interface kicked off against the disk needs this before it can
/// be asserted on.
Future<void> settleDisk(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
}

/// Waits until the disk actually shows what was asked of it.
///
/// A fixed delay was a guess, and on a loaded machine the wrong one: the tap
/// starts a read of the profile and only then a queued write, so there is no
/// single moment to sleep until. Waiting for the result is exact, and giving
/// up after a few seconds is still a failure rather than a hang.
Future<T> waitForDisk<T>(
  WidgetTester tester,
  Future<T?> Function() read, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final result = await tester.runAsync(() async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final value = await read();
      if (value != null) return value;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  });
  if (result == null) {
    fail('Die Platte hat in ${timeout.inSeconds} s nichts geliefert');
  }
  return result;
}

Future<void> openVault(
  WidgetTester tester,
  LibraryController library,
  Directory root,
) async {
  await tester.runAsync(() => library.open(root, createIfMissing: true));
}

Future<void> pumpShell(
  WidgetTester tester, {
  required LibraryController library,
  required AppSettings settings,
  FundusRoute route = const DashboardRoute(),
}) async {
  tester.view.physicalSize = _desktop;
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
  scope.navigation.reset(route);
  // Bounded on purpose: a widget that never stops animating is a bug, and the
  // ten-minute default would hide it behind a timeout at the end of the suite.
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-shell-');
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('ohne Bibliothek führt jeder Weg zur Auswahl', (tester) async {
    await pumpShell(tester, library: library, settings: settings);

    expect(find.text('Bibliothek öffnen'), findsOneWidget);
    expect(find.text('Neue Bibliothek anlegen'), findsOneWidget);
  });

  testWidgets('eine leere Bibliothek erklärt, warum sie leer ist', (
    tester,
  ) async {
    await openVault(tester, library, root);
    await pumpShell(tester, library: library, settings: settings);

    expect(find.text('Diese Bibliothek ist noch leer'), findsOneWidget);
    expect(
      find.textContaining('Der Scan liest den Ordner ein'),
      findsOneWidget,
    );
    expect(find.text('Jetzt scannen'), findsOneWidget);
  });

  testWidgets('die Seitenleiste trägt Ort, Bereiche und Fußzeile', (
    tester,
  ) async {
    await openVault(tester, library, root);
    await pumpShell(tester, library: library, settings: settings);

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Alle Werke'), findsOneWidget);
    expect(find.text('Hörbücher'), findsOneWidget);
    expect(find.text('Manga & Comics'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Einstellungen'), findsOneWidget);
  });

  testWidgets('eingeklappt bleibt es dieselbe Navigation', (tester) async {
    await openVault(tester, library, root);
    await settings.setNavigationCollapsed(true);
    await pumpShell(tester, library: library, settings: settings);

    // Labels weichen, die Einträge bleiben — als Icons mit Tooltip.
    expect(find.text('Hörbücher'), findsNothing);
    expect(find.byTooltip('Hörbücher'), findsOneWidget);
  });

  testWidgets('die Einstellungen übernehmen dieselbe Leiste', (tester) async {
    await openVault(tester, library, root);
    await pumpShell(
      tester,
      library: library,
      settings: settings,
      route: const SettingsRoute(),
    );

    // Nie zwei Seitenleisten: die Bereiche ersetzen die Medientypen.
    expect(find.text('Zurück zum Dashboard'), findsOneWidget);
    expect(find.text('Hörbücher'), findsNothing);
    expect(find.text('Geräte & Abgleich'), findsWidgets);
    // Downloads und Einstellungen bleiben unten stehen.
    expect(find.text('Downloads'), findsOneWidget);
  });

  testWidgets('das Thema lässt sich umschalten und bleibt gespeichert', (
    tester,
  ) async {
    await openVault(tester, library, root);
    await pumpShell(
      tester,
      library: library,
      settings: settings,
      // Ohne Bereich ist die Route die Übersicht; das Thema steht in einem.
      route: const SettingsRoute(category: 'darstellung'),
    );

    expect(settings.themeMode, ThemeMode.dark);
    // Der Tap läuft in der echten Zone: sein Handler schreibt das Profil in
    // die Bibliothek, und das ist Datei-Arbeit.
    await tester.runAsync(() => tester.tap(find.text('Hell')));
    await settleDisk(tester);
    await tester.pump();

    expect(settings.themeMode, ThemeMode.light);
    // Und die Bibliothek merkt es sich für dieses Gerät.
    final theme = await waitForDisk(tester, () async {
      await library.library!.flushSidecarWrites();
      final profile = await library.library!.loadDeviceProfile(
        settings.deviceKey,
      );
      return profile?.settingsFor('shell')['theme_mode'];
    });
    expect(theme, 'light');
  });

  testWidgets('die Pfadleiste führt zurück', (tester) async {
    await openVault(tester, library, root);
    await pumpShell(
      tester,
      library: library,
      settings: settings,
      route: const LibraryRoute(),
    );

    expect(find.text('Alle Werke'), findsWidgets);
    expect(find.text('Ordnen nach'), findsOneWidget);
  });
}
