import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/work_filter.dart';
import 'package:fundus_design/fundus_design.dart';

/// „Das mag ich."
///
/// Eine Aussage über das Werk, also gehört sie in die Bibliothek und nicht
/// auf ein Gerät — sonst stimmt sie auf dem Handy nicht.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-fav-');
    for (final title in ['Arrival', 'Dune']) {
      final folder = Directory('${root.path}/Filme/$title')
        ..createSync(recursive: true);
      File('${folder.path}/$title.mkv').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root, createIfMissing: true);
    await library.scan();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('ein Werk lässt sich als Favorit merken', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
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
    final work = library.works.firstWhere((entry) => entry.title == 'Dune');
    scope.navigation.reset(WorkRoute(work.id));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zu den Favoriten'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Aus den Favoriten nehmen'), findsOneWidget);
    expect(library.workById(work.id)!.summary.favourite, isTrue);

    // Und der Filter findet genau dieses eine.
    const filter = WorkFilter(favouritesOnly: true);
    expect(filter.apply(library.works).map((w) => w.title), ['Dune']);

    await tester.tap(find.byTooltip('Aus den Favoriten nehmen'));
    await tester.pumpAndSettle();
    expect(library.workById(work.id)!.summary.favourite, isFalse);
  });

  test('ohne Favoriten filtert der Filter alles weg', () {
    const filter = WorkFilter(favouritesOnly: true);

    expect(filter.apply(library.works), isEmpty);
    expect(filter.emptyReason(), contains('Favoriten'));
  });
}
