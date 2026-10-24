import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fullscreen.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/protection.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show FakePageSource;
import 'fullscreen_test.dart' show FakeFullscreen;
import 'shell_test.dart' show waitForDisk;

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;
  late ReaderController reader;
  late FullscreenController fullscreen;
  late String visible;
  late String hidden;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-updates-ui-');
    for (final title in ['Visible', 'Private']) {
      final folder = Directory('${root.path}/Manga/$title')
        ..createSync(recursive: true);
      File('${folder.path}/01.cbz').writeAsBytesSync([1, 2, 3]);
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
    reader = ReaderController(
      openSource: (path, name) => FakePageSource(name, 8),
    );
    fullscreen = FullscreenController(mode: FakeFullscreen());
    await library.open(root, createIfMissing: true);
    await library.scan();
    visible = library.works.firstWhere((work) => work.title == 'Visible').id;
    hidden = library.works.firstWhere((work) => work.title == 'Private').id;
    final vault = library.library!;
    final work = vault.workSummary(hidden)!;
    await vault.updateWorkMetadata(
      workId: hidden,
      title: work.title,
      authors: work.authors,
      contentSensitivity: 'adult_explicit',
    );
    await vault.subscribeContentWorks({visible, hidden});
    for (final title in ['Visible', 'Private']) {
      File('${root.path}/Manga/$title/02.cbz').writeAsBytesSync([4, 5, 6]);
    }
    await library.scan();
  });

  tearDown(() async {
    fullscreen.dispose();
    reader.dispose();
    player.dispose();
    await library.library?.flushSidecarWrites();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(
    WidgetTester tester, {
    bool mobile = true,
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(430, 932)
        : const Size(1400, 900);
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
          reader: reader,
          fullscreen: fullscreen,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(const ContentUpdatesRoute());
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets(
    'mobile inbox filters protected events and counts before rendering',
    (tester) async {
      await settings.setProtectionMode(ProtectionMode.hide);
      await pump(tester);
      expect(find.text('Visible'), findsOneWidget);
      expect(find.text('Private'), findsNothing);
      expect(library.contentUpdates, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('locking an open inbox immediately removes protected history', (
    tester,
  ) async {
    await settings.setProtectionMode(ProtectionMode.hide);
    final scope = await pump(tester, mobile: false);
    await scope.protection.unlockAuthenticatedSession();
    await tester.pumpAndSettle();
    expect(find.text('Private'), findsOneWidget);
    scope.protection.lock();
    await tester.pumpAndSettle();
    expect(find.text('Private'), findsNothing);
    expect(library.contentUpdates, hasLength(1));
  });

  testWidgets('snoozing a notice persists without changing reading progress', (
    tester,
  ) async {
    await settings.setProtectionMode(ProtectionMode.hide);
    await pump(tester);
    final id = library.contentUpdates.single.id;
    await tester.tap(find.byTooltip('Hinweis bearbeiten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Später ansehen'));
    await tester.pump();
    await waitForDisk(tester, () async {
      await library.library!.flushSidecarWrites();
      return library.library!.contentUpdates
                  .firstWhere((event) => event.id == id)
                  .disposition ==
              ContentUpdateDisposition.later
          ? true
          : null;
    });
    await tester.pumpAndSettle();
    expect(
      library.library!.contentUpdates
          .firstWhere((event) => event.id == id)
          .disposition,
      ContentUpdateDisposition.later,
    );
    expect(library.library!.loadProgress(visible), isNull);
    expect(find.text('Visible'), findsNothing);
    await tester.tap(find.text('Neue Hinweise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Später ansehen').last);
    await tester.pumpAndSettle();
    expect(find.text('Visible'), findsOneWidget);
  });

  testWidgets(
    'open this part reaches the new manga volume, not the saved first volume',
    (tester) async {
      await settings.setProtectionMode(ProtectionMode.hide);
      await pump(tester);
      await tester.tap(find.byTooltip('Hinweis bearbeiten'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Diesen Teil öffnen'));
      await tester.pump();
      // The popup's route future resumes in the widget test's fake zone.
      // Drive frames between real-I/O turns so each reader await can resume.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          (reader.currentVolume?.title != '02.cbz' || reader.isBusy) &&
          reader.failure == null) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(reader.failure, isNull);
      expect(reader.currentVolume?.title, '02.cbz');
      expect(reader.pageIndex, 0);
      expect(player.work, isNull);
    },
  );
}
