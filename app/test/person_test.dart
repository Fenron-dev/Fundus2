import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/people/person_credits.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Eine Person steht am Werk und nicht am Regal: wer einen Sprecher antippt,
/// will alles von ihm sehen.
void main() {
  group('die Anfangsbuchstaben', () {
    test('zwei Namen werden zwei Buchstaben', () {
      expect(initialsOf('Marit Sölden'), 'MS');
      expect(initialsOf('  karl   may '), 'KM');
    });

    test('ein einzelner Name behält zwei Buchstaben', () {
      expect(initialsOf('Homer'), 'HO');
      expect(initialsOf('X'), 'X');
      expect(initialsOf('   '), '?');
    });
  });

  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-person-');
    for (final title in ['Der Schacht', 'Die Tiefe']) {
      final folder = Directory('${root.path}/Hörbücher/Karl May/$title')
        ..createSync(recursive: true);
      await File('${folder.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    }
    final other = Directory('${root.path}/Hörbücher/Anders/Ganz anderes')
      ..createSync(recursive: true);
    await File('${other.path}/01.mp3').writeAsBytes(List.filled(64, 1));

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

  test('die Werke einer Person kommen aus dem ganzen Katalog', () {
    final found = worksOfPerson('Karl May', library.works);

    expect(found.map((entry) => entry.work.title), [
      'Der Schacht',
      'Die Tiefe',
    ]);
    expect(found.first.roles, contains(CreditRole.author));
    // Und Groß- und Kleinschreibung entscheidet nicht über Menschen.
    expect(worksOfPerson('karl may', library.works), hasLength(2));
  });

  testWidgets('die Personenseite zeigt, was von ihr da ist', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.go(const PersonRoute('Karl May'));
    await tester.pumpAndSettle();

    expect(find.text('Karl May'), findsWidgets);
    expect(find.text('Der Schacht'), findsOneWidget);
    expect(find.text('Die Tiefe'), findsOneWidget);
    expect(find.text('Ganz anderes'), findsNothing);
  });
}
