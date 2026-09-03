import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fullscreen.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/reader/text_reader_screen.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus/media/text_reader_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import 'fullscreen_test.dart' show FakeFullscreen;
import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show FakePageSource, writeArchive;
import 'text_reader_test.dart' show FakeTextSource;

/// Two things that only show on screen: the chosen font has to reach the
/// text, and a page narrower than the window belongs in the middle.
void main() {
  group('Die gewählte Schrift kommt beim Text an', () {
    late Directory root;
    late LibraryController library;
    late AppSettings settings;
    late TextReaderController reader;
    late FullscreenController fullscreen;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-font-');
      Directory(
        '${root.path}/Light Novels/Glasmeer',
      ).createSync(recursive: true);
      File(
        '${root.path}/Light Novels/Glasmeer/Band 01.epub',
      ).writeAsBytesSync(List.filled(64, 5));
      library = LibraryController();
      settings = AppSettings.inMemory();
      reader = TextReaderController(
        openSource: (path, name) => FakeTextSource(name, const ['Eins']),
      );
      fullscreen = FullscreenController(mode: FakeFullscreen());
    });

    tearDown(() async {
      fullscreen.dispose();
      reader.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    testWidgets('eine andere Schrift ändert den Text wirklich', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late FundusScopeState scope;
      await tester.runAsync(() async {
        await library.open(root, createIfMissing: true);
        await library.scan();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: FundusTheme.dark(),
          home: FundusScope(
            settings: settings,
            library: library,
            player: PlaybackController(engine: FakeEngine()),
            reader: ReaderController(
              openSource: (path, name) => FakePageSource(name, 4),
            ),
            textReader: reader,
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
      final novel = library.works.first;
      scope.navigation.reset(WorkRoute(novel.id));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await tester.runAsync(() => scope.play(novel));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(reader.isOpen, isTrue);

      TextStyle firstParagraphStyle() {
        final text = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .first;
        return text.style!;
      }

      // Systemschrift heißt: keine besondere Familie verlangen.
      expect(firstParagraphStyle().fontFamily, isNull);

      await tester.runAsync(
        () => reader.updateProfile(
          reader.profile.copyWith(fontFamily: ReflowFontFamily.serif),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      final serif = firstParagraphStyle();
      expect(serif.fontFamily, 'Georgia');
      // Und ein Ersatz für Geräte ohne Georgia.
      expect(serif.fontFamilyFallback, isNotEmpty);
      expect(serif.fontFamilyFallback, contains('serif'));

      await tester.runAsync(
        () => reader.updateProfile(
          reader.profile.copyWith(fontFamily: ReflowFontFamily.monospace),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(firstParagraphStyle().fontFamily, 'Menlo');
    });

    test('jede Wahl nennt eine echte Familie, nicht einen CSS-Namen', () {
      // „serif" allein ist ein CSS-Wort und benennt für Flutter nichts.
      for (final family in ReflowFontFamily.values) {
        final font = fontFor(family);
        if (family == ReflowFontFamily.system) {
          expect(font.family, isNull);
          continue;
        }
        expect(font.family, isNotNull);
        expect(
          const {'serif', 'sans-serif', 'monospace'},
          isNot(contains(font.family)),
          reason: '${family.name} verlangt nur einen CSS-Namen',
        );
        expect(font.fallback, isNotEmpty);
      }
    });
  });

  group('Eine Seite steht in der Mitte', () {
    late Directory root;
    late LibraryController library;
    late AppSettings settings;
    late ReaderController reader;
    late FullscreenController fullscreen;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-centre-');
      final work = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      writeArchive(work, 'Band 01.cbz', ['001.jpg', '002.jpg']);
      library = LibraryController();
      settings = AppSettings.inMemory();
      reader = ReaderController(
        openSource: (path, name) => FakePageSource(name, 6),
      );
      fullscreen = FullscreenController(mode: FakeFullscreen());
    });

    tearDown(() async {
      fullscreen.dispose();
      reader.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    testWidgets('im fortlaufenden Modus sitzt jede Seite mittig', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late FundusScopeState scope;
      await tester.runAsync(() async {
        await library.open(root, createIfMissing: true);
        await library.scan();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: FundusTheme.dark(),
          home: FundusScope(
            settings: settings,
            library: library,
            player: PlaybackController(engine: FakeEngine()),
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
      final manga = library.works.first;
      scope.navigation.reset(WorkRoute(manga.id));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await tester.runAsync(() async {
        await scope.play(manga);
        await reader.updateProfile(
          reader.profile.copyWith(layout: PublicationReaderLayout.webtoon),
        );
      });
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(reader.isContinuous, isTrue);
      // Jede Seite im Strip hängt in einem Center, nicht links am Rand.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Center),
        ),
        findsWidgets,
      );
    });
  });
}
