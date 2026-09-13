import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_core/fundus_core.dart';
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

/// Legt ein Hörbuch an und liest es ein.
///
/// Seit leere Medienarten nicht mehr in der Leiste stehen, braucht ein Test
/// über die Leiste auch etwas darin — sonst prüft er die Abwesenheit von
/// allem.
Future<void> seedAudiobook(
  WidgetTester tester,
  LibraryController library,
  Directory root,
) async {
  await tester.runAsync(() async {
    final book = Directory('${root.path}/Hörbücher/Karl May/Winnetou');
    await book.create(recursive: true);
    await File('${book.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);
    await library.open(root, createIfMissing: true);
    await library.scan();
  });
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
    await seedAudiobook(tester, library, root);
    await pumpShell(tester, library: library, settings: settings);

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Alle Werke'), findsOneWidget);
    expect(find.text('Hörbücher'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Einstellungen'), findsOneWidget);
  });

  testWidgets('leere Medienarten stehen nicht in der Leiste', (tester) async {
    // „Serien 0" stand dauerhaft da: die Bedingung lautete „Anzahl > 0 oder
    // nicht geschützt", und geschützt ist nur das geschützte Regal.
    await seedAudiobook(tester, library, root);
    await pumpShell(tester, library: library, settings: settings);

    expect(find.text('Hörbücher'), findsOneWidget);
    expect(find.text('Serien'), findsNothing);
    expect(find.text('Manga & Comics'), findsNothing);
    expect(find.text('Filme'), findsNothing);
  });

  testWidgets('eingeklappt bleibt es dieselbe Navigation', (tester) async {
    await seedAudiobook(tester, library, root);
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

  testWidgets('zwei Bibliotheken werden gruppiert statt flach verdoppelt', (
    tester,
  ) async {
    // Vorher standen die Gruppen *zusätzlich* zur flachen Liste: dieselben
    // Namen zweimal, einmal summiert und einmal aufgeschlüsselt, ohne dass
    // die Leiste sagt welche welche ist.
    await seedAudiobook(tester, library, root);
    await tester.runAsync(() async {
      final vault = library.library!;
      vault.registerPeerSource(
        sourceId: 'peer-zweite',
        displayName: 'Zweite Bibliothek',
        libraryId: 'lib-2',
        baseUrl: 'https://127.0.0.1:1',
      );
      vault.mirrorRemoteCatalogue(
        sourceId: 'peer-zweite',
        works: const [
          RemoteWorkRecord(
            id: 'remote-werk-1',
            kind: 'manga',
            title: 'Klingenwind',
            files: [
              RemoteFileRecord(
                id: 'remote-datei-1',
                filename: '01.cbz',
                position: 0,
                extension: 'cbz',
              ),
            ],
          ),
        ],
      );
      library.refresh();
    });
    await pumpShell(tester, library: library, settings: settings);

    // Die Überschrift und beide Bibliotheken stehen da.
    expect(find.text('BIBLIOTHEKEN'), findsOneWidget);
    expect(find.text('Auf diesem Gerät'), findsOneWidget);
    expect(find.text('Zweite Bibliothek'), findsOneWidget);

    // „Alle Werke" bleibt oben: es gilt über beide hinweg.
    expect(find.text('Alle Werke'), findsOneWidget);

    // Die Medienart steht nicht mehr flach daneben — sie gehört jetzt in die
    // Gruppe der Bibliothek, die sie enthält.
    expect(find.text('Hörbücher'), findsNothing);
  });

  testWidgets('eine aufgeklappte Bibliothek bleibt aufgeklappt', (
    tester,
  ) async {
    // Der Zustand lag nur im Widget; die mobile Schublade baut die Leiste bei
    // jedem Öffnen neu, und damit klappte jede Bibliothek jedes Mal wieder zu.
    await settings.setSourceExpanded('peer-zweite', true);
    expect(settings.expandedSources, contains('peer-zweite'));

    final wieder = AppSettings.inMemory();
    await wieder.setSourceExpanded('peer-zweite', true);
    expect(wieder.expandedSources, contains('peer-zweite'));
    await wieder.setSourceExpanded('peer-zweite', false);
    expect(wieder.expandedSources, isEmpty);
  });
}
