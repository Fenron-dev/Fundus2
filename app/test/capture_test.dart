import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fullscreen.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/capture.dart';
import 'package:fundus/media/comic_layout.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'fullscreen_test.dart' show FakeFullscreen;
import 'playback_controller_test.dart' show FakeEngine;
import 'reader_test.dart' show writeArchive;

/// A stand-in for the system's save dialog.
final class FakeSink implements CaptureSink {
  final List<({int length, String name})> saved = [];
  String? answer = '/tmp/gespeichert.png';

  @override
  Future<String?> save(Uint8List bytes, {required String suggestedName}) async {
    saved.add((length: bytes.length, name: suggestedName));
    return answer;
  }
}

void main() {
  group('Eine Seite lässt sich sichern', () {
    late Directory root;
    late LibraryController library;
    late AppSettings settings;
    late ReaderController reader;
    late PlaybackController player;
    late FakeEngine engine;
    late FakeSink sink;
    late FullscreenController fullscreen;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-capture-');
      library = LibraryController();
      settings = AppSettings.inMemory();
      engine = FakeEngine();
      player = PlaybackController(engine: engine);
      reader = ReaderController();
      sink = FakeSink();
      fullscreen = FullscreenController(mode: FakeFullscreen());
    });

    tearDown(() async {
      fullscreen.dispose();
      reader.dispose();
      player.dispose();
      library.dispose();
      await root.delete(recursive: true);
    });

    testWidgets('die gezeigte Seite geht in den Speichern-Dialog', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final work = Directory('${root.path}/Manga/Klingenwind')
        ..createSync(recursive: true);
      writeArchive(work, 'Kapitel 01.cbz', ['001.jpg', '002.jpg']);

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
            reader: reader,
            fullscreen: fullscreen,
            captureSink: sink,
            child: Builder(
              builder: (context) {
                scope = FundusScope.of(context);
                return const FundusShell();
              },
            ),
          ),
        ),
      );
      scope.navigation.reset(WorkRoute(library.works.first.id));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await tester.runAsync(() => scope.play(library.works.first));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      // Geöffnet wird gleich im Vollbild; der Knopf sitzt in der Leiste,
      // die dafür erst zurückgeholt werden muss.
      reader.showChrome();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      // Erst wenn die Seite wirklich ausgepackt ist, gibt es etwas zu
      // sichern. Auf einer belegten Maschine dauert das länger als eine feste
      // Wartezeit — also wird gewartet, bis es so weit ist, statt zu hoffen.
      await tester.runAsync(() async {
        for (var tries = 0; tries < 100; tries++) {
          if (reader.currentPageFile != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();
      expect(
        reader.currentPageFile,
        isNotNull,
        reason: 'Die Seite wurde nie ausgepackt',
      );

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Seite speichern'));
        for (var tries = 0; tries < 100; tries++) {
          if (sink.saved.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();

      expect(sink.saved, hasLength(1));
      expect(sink.saved.single.length, greaterThan(0));
      expect(sink.saved.single.name, contains('Klingenwind'));
      expect(sink.saved.single.name, endsWith('.jpg'));
      // Und die Stelle ist wiederzufinden.
      expect(reader.bookmarks, hasLength(1));
      expect(reader.bookmarks.single.note, '/tmp/gespeichert.png');
    });

    test('ein Hörbuch hat kein Bild zu sichern', () async {
      final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
        ..createSync(recursive: true);
      File('${work.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));

      await library.open(root, createIfMissing: true);
      await library.scan();
      await player.open(library.library!, library.works.first);

      expect(player.showsVideo, isFalse);
      expect(await player.captureFrame(), isNull);
    });
  });

  group('Eine Lücke in der Kapitelnummerierung wird genannt', () {
    test('fehlende Nummern werden gefunden', () {
      final sequence = comicChapterSequence([
        'Kapitel 01.cbz',
        'Kapitel 02.cbz',
        'Kapitel 04.cbz',
        'Kapitel 05.cbz',
      ]);

      expect(sequence.missing, [3]);
      expect(sequence.duplicates, isEmpty);
      expect(sequence.summary, contains('Kapitel 3 fehlt'));
    });

    test('doppelte Nummern werden gefunden', () {
      final sequence = comicChapterSequence([
        'Chapter 7.cbz',
        'Chapter 7 (v2).cbz',
      ]);

      expect(sequence.duplicates, {7.0});
      expect(sequence.summary, contains('doppelt'));
    });

    test('eine lückenlose Reihe meldet nichts', () {
      final sequence = comicChapterSequence([
        'Band 01.cbz',
        'Band 02.cbz',
        'Band 03.cbz',
      ]);

      expect(sequence.hasIssues, isFalse);
      expect(sequence.summary, isNull);
    });

    test('Zwischenkapitel gelten nicht als Lücke', () {
      final sequence = comicChapterSequence([
        'Kapitel 1.cbz',
        'Kapitel 1.5.cbz',
        'Kapitel 2.cbz',
      ]);

      expect(sequence.missing, isEmpty);
      expect(sequence.hasIssues, isFalse);
    });

    test('Titel ohne Nummer stürzen nicht ab', () {
      final sequence = comicChapterSequence(['Prolog.cbz', 'Epilog.cbz']);

      expect(sequence.numbers, [null, null]);
      expect(sequence.hasIssues, isFalse);
    });

    test('eine Jahreszahl im Titel erfindet keine tausend Lücken', () {
      final sequence = comicChapterSequence(['Band 1.cbz', 'Band 2024.cbz']);

      expect(sequence.missing, isEmpty);
    });
  });
}
