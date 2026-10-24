import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/protection.dart';
import 'package:fundus/features/work/metadata_history_dialog.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:image/image.dart' as image;

import 'playback_controller_test.dart' show FakeEngine;

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;
  late String id, other;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-history-ui-');
    for (final title in ['Visible', 'Other']) {
      final folder = await Directory(
        '${root.path}/Manga/$title',
      ).create(recursive: true);
      await File('${folder.path}/01.cbz').writeAsBytes([1, 2, 3]);
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
    await library.open(root, createIfMissing: true);
    await library.scan();
    id = library.works.firstWhere((work) => work.title == 'Visible').id;
    other = library.works.firstWhere((work) => work.title == 'Other').id;
    await MetadataEditBatch.run(
      source: 'user:test',
      action: () async {
        await library.library!.updateWorkMetadata(
          workId: id,
          title: 'Revised',
          authors: ['Author'],
        );
        await library.library!.updateWorkMetadata(
          workId: other,
          title: 'Other revised',
          authors: ['Author'],
        );
      },
    );
    library.refresh();
  });
  tearDown(() async {
    player.dispose();
    await library.library?.shutdown();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
              return Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        showMetadataHistory(context, scope: scope, workId: id),
                    child: const Text('Verlauf öffnen'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scope;
  }

  Future<void> open(WidgetTester tester, String source) async {
    await tester.tap(find.text('Verlauf öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(' · $source'));
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester, bool Function() done) async {
    await tester.pump();
    for (var attempt = 0; attempt < 250 && !done(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone shows a comparison and rolls back only the selected title',
    (tester) async {
      await pump(tester);
      await open(tester, 'user:test');
      await tester.scrollUntilVisible(
        find.text('Titel'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Titel'));
      await tester.pump();
      await tester.tap(find.text('1 Felder zurücknehmen'));
      await settleIo(tester, () => library.workById(id)?.title == 'Visible');
      expect(library.workById(other)!.title, 'Other revised');
      expect(library.library!.workSummary(id)!.authors, ['Author']);
      expect(find.textContaining('1 Felder zurückgenommen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picture comparison restores the selected earlier cover', (
    tester,
  ) async {
    final firstImage = image.fill(
      image.Image(width: 2, height: 2),
      color: image.ColorRgb8(255, 0, 0),
    );
    final secondImage = image.fill(
      image.Image(width: 2, height: 2),
      color: image.ColorRgb8(0, 0, 255),
    );
    late String first;
    await tester.runAsync(() async {
      first = await library.library!.cacheGeneratedCover(
        workId: id,
        bytes: image.encodePng(firstImage),
      );
      await library.library!.cacheGeneratedCover(
        workId: id,
        bytes: image.encodePng(secondImage),
      );
    });
    library.refreshWork(id);
    await pump(tester);
    await tester.tap(find.text('Verlauf öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(' · user').first);
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 100 &&
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Titelbild'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Bisher'), findsOneWidget);
    expect(find.text('Danach'), findsOneWidget);
    await tester.tap(find.text('Titelbild'));
    await tester.pump();
    await tester.tap(find.text('1 Felder zurücknehmen'));
    await settleIo(
      tester,
      () =>
          find.textContaining('1 Felder zurückgenommen').evaluate().isNotEmpty,
    );
    expect(library.library!.workSummary(id)?.coverPath, first);
    expect(find.textContaining('1 Felder zurückgenommen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retention can be adjusted from the history dialog', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Verlauf öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aufbewahrung'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('25 Änderungspakete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Übernehmen'));
    await settleIo(
      tester,
      () => find.text('Aufbewahrung aktualisiert.').evaluate().isNotEmpty,
    );
    expect(library.library!.metadataHistoryPolicy.retainBatches, 25);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'whole batch is explicit and includes only currently visible works',
    (tester) async {
      await pump(tester);
      await open(tester, 'user:test');
      await tester.tap(
        find.text('Andere sichtbare Werke dieses Änderungspakets einbeziehen'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unveränderte Felder auswählen'));
      await tester.pump();
      final apply = find.byWidgetPredicate(
        (widget) => widget is FilledButton && widget.onPressed != null,
      );
      await tester.tap(apply);
      await settleIo(
        tester,
        () =>
            library.workById(id)?.title == 'Visible' &&
            library.workById(other)?.title == 'Other',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('locking removes an expanded protected comparison immediately', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final field = await library.library!.savePropertyDefinition(
        mediaKind: '',
        name: 'Private field label',
        valueType: PropertyValueType.text,
        protected: true,
      );
      await MetadataEditBatch.run(
        source: 'private-field',
        action: () => library.library!.setWorkProperty(
          workId: id,
          definitionId: field.id,
          value: 'private historical value',
        ),
      );
    });
    await settings.setProtectionMode(ProtectionMode.hide);
    final scope = await pump(tester);
    await scope.protection.unlockAuthenticatedSession();
    await tester.pumpAndSettle();
    await open(tester, 'private-field');
    expect(find.text('Private field label'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Vergleich vergrößern'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vergleich vergrößern'));
    await tester.pump();
    expect(find.textContaining('private historical value'), findsOneWidget);
    scope.protection.lock();
    await tester.pumpAndSettle();
    expect(find.textContaining('private historical value'), findsNothing);
    expect(find.text('Private field label'), findsNothing);
    expect(find.textContaining('private-field'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newer field edit disables its rollback selection', (
    tester,
  ) async {
    await pump(tester);
    await open(tester, 'user:test');
    await tester.runAsync(
      () => library.library!.updateWorkMetadata(
        workId: id,
        title: 'Newer',
        authors: ['Author'],
      ),
    );
    library.refreshWork(id);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Titel'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    final tile = tester.widget<CheckboxListTile>(
      find.ancestor(
        of: find.text('Titel'),
        matching: find.byType(CheckboxListTile),
      ),
    );
    expect(tile.onChanged, isNull);
    expect(find.textContaining('Seitdem geändert'), findsWidgets);
    expect(library.workById(id)!.title, 'Newer');
  });
}
