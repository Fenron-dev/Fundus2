import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Die Staffelzeile.
///
/// Auch eine Sendung mit nur einer Staffel bekommt sie: „Staffel 1 · 2
/// Folgen" ist eine Auskunft, kein Bedienelement — und genau die fehlte auf
/// der Seite von Chainsaw Man.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-staffel-');
    final show = Directory('${root.path}/Anime/Chainsaw Man')
      ..createSync(recursive: true);
    for (final name in ['S01E01 - DOG & CHAINSAW', 'S01E02 - ARRIVAL']) {
      File('${show.path}/$name.mkv').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('eine einzelne Staffel wird trotzdem benannt', (tester) async {
    tester.view.physicalSize = const Size(1000, 1300);
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
          player: player,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(WorkRoute(library.works.single.id));
    await tester.pumpAndSettle();

    expect(find.text('Staffel 1'), findsOneWidget);
    expect(find.text('2 Folgen'), findsOneWidget);
  });
}
