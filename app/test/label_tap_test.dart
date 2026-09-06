import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/work/work_screen.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Ein Schlagwort auf der Werkseite ist keine Beschriftung, sondern eine
/// Frage: was habe ich noch damit?
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-schlagwort-');
    for (final show in ['Auf ein Bier', 'Ganz anderes']) {
      final folder = Directory('${root.path}/Podcasts/$show');
      await folder.create(recursive: true);
      await File('${folder.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    }
    final vault = await FundusLibrary.create(root);
    await vault.index().drain<void>();
    final works = vault.listWorks();
    await vault.replaceWorkTags(
      works.firstWhere((work) => work.title == 'Auf ein Bier').id,
      ['Video Games'],
    );
    vault.close();

    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root);
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('ein Tipp auf „Video Games" zeigt, was das noch trägt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final work = library.works.firstWhere(
      (candidate) => candidate.title == 'Auf ein Bier',
    );
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
              return Scaffold(body: WorkScreen(workId: work.id));
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Video Games'), findsWidgets);
    await tester.tap(find.text('Video Games').first);
    await tester.pump();

    // Der Filter steht auf dem Schlagwort, über alle Bibliotheken hinweg.
    expect(scope.filter.tags, {'Video Games'});
    expect(scope.filter.mediaTypeId, isNull);
    expect(
      scope.filter.apply(library.works).map((WorkView view) => view.title),
      ['Auf ein Bier'],
    );
  });
}
