import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// „Vorschlag für heute" heißt: für heute.
///
/// Aus dem Betrieb: einmal vor und zurück, und der Vorschlag war ein
/// anderer — was ihn zu keinem Vorschlag mehr macht, sondern zu Rauschen.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-vorschlag-');
    final folder = Directory('${root.path}/Musik/Kraftwerk/Autobahn')
      ..createSync(recursive: true);
    await File('${folder.path}/01.mp3').writeAsBytes(List.filled(64, 1));
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

  testWidgets('der Würfel bleibt liegen, bis jemand ihn anfasst', (
    tester,
  ) async {
    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          scanner: const NoPairingScanner(),
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );

    final first = scope.suggestionSeed;
    await tester.pump();
    // Ein neuer Aufbau würfelt nicht neu.
    expect(scope.suggestionSeed, first);

    scope.reshuffleSuggestion();
    await tester.pump();

    expect(scope.suggestionSeed, isNot(first));
    // Und derselbe Würfel zieht dasselbe Werk.
    final drawn = [1, 2, 3, 4, 5]..shuffle(Random(scope.suggestionSeed));
    final again = [1, 2, 3, 4, 5]..shuffle(Random(scope.suggestionSeed));
    expect(drawn, again);
  });
}
