import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/settings/settings_screen.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Die Wartungsseite sagt, was da ist — und nur, was da ist.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-wartungsseite-');
    final album = Directory('${root.path}/Musik/Kraftwerk/Autobahn');
    await album.create(recursive: true);
    for (var track = 1; track <= 3; track++) {
      await File(
        '${album.path}/0$track.mp3',
      ).writeAsBytes(List.filled(4096 * track, 1));
    }
    final vault = await FundusLibrary.create(root);
    await vault.index().drain<void>();
    vault.close();

    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root);
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          scanner: const NoPairingScanner(),
          child: const Scaffold(body: SettingsScreen(category: 'wartung')),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('sie zeigt den Bestand, das Laufende und die Aufgaben', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Serverwartung'), findsWidgets);
    expect(find.text('Speicher'), findsOneWidget);
    expect(find.text('Läuft gerade'), findsOneWidget);
    expect(find.text('Durchgänge'), findsOneWidget);
    expect(find.text('Aufgaben'), findsOneWidget);
    expect(find.text('Protokoll'), findsOneWidget);
    // Die Musik steht mit ihrer Größe da — 24 kB in drei Dateien.
    expect(find.text('Musik'), findsWidgets);
    expect(find.textContaining('an Mediendateien im Katalog'), findsOneWidget);
    // Nichts läuft, und das wird auch so gesagt.
    expect(find.text('Nichts. Der Server wartet.'), findsOneWidget);
  });

  testWidgets('ohne Verwaiste ist das Aufräumen nicht anzutippen', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(
      find.text('Der Katalog zeigt auf nichts, das es nicht gibt.'),
      findsOneWidget,
    );
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Aufräumen'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('was verschwunden ist, wird gezählt und lässt sich wegräumen', (
    tester,
  ) async {
    // Der Durchgang läuft auf einem Worker und braucht echte Zeit; in der
    // Scheinzeit von `testWidgets` käme er nie zurück.
    await tester.runAsync(() async {
      await Directory(
        '${root.path}/Musik/Kraftwerk/Autobahn',
      ).delete(recursive: true);
      await library.scan();
    });
    await pumpPage(tester);

    expect(find.textContaining('Dateien fehlen'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Aufräumen'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });
}
