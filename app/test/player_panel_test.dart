import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/player/player_screen.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// The list beside the transport. A work made of several files is not a work
/// with chapters: showing twelve episodes as "Kapitel", all at 00:00, is how
/// the first video attempt looked.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late FakeEngine engine;
  late PlaybackController player;

  Future<void> pumpPlayer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          // Im Betrieb liegt der Player über der Shell, die das Material stellt.
          child: const Scaffold(body: PlayerScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-panel-');
    library = LibraryController();
    settings = AppSettings.inMemory();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('mehrere Folgen heißen Folgen, nicht Kapitel', (tester) async {
    final series = Directory('${root.path}/Anime/Chainsaw Man')
      ..createSync(recursive: true);
    for (final episode in ['S01E01 - Dog', 'S01E02 - Tokyo']) {
      File('${series.path}/$episode.mkv').writeAsBytesSync(List.filled(64, 3));
    }

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await player.open(library.library!, library.works.first);
    });
    await pumpPlayer(tester);

    expect(find.text('FOLGEN'), findsOneWidget);
    expect(find.text('KAPITEL'), findsNothing);
    expect(find.textContaining('S01E01'), findsWidgets);
  });

  testWidgets('zweisprachiger Ton ist wählbar', (tester) async {
    final series = Directory('${root.path}/Anime/Chainsaw Man')
      ..createSync(recursive: true);
    File(
      '${series.path}/S01E01 - Dog.mkv',
    ).writeAsBytesSync(List.filled(64, 3));

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await player.open(library.library!, library.works.first);
      engine.emitTracks(
        const MediaTracks(
          audio: [
            MediaTrackOption(id: '1', label: 'Japanisch'),
            MediaTrackOption(id: '2', label: 'Deutsch'),
          ],
          subtitles: [
            MediaTrackOption(id: 'no', label: 'Aus'),
            MediaTrackOption(id: '3', label: 'Deutsch'),
          ],
          selectedAudioId: '1',
          selectedSubtitleId: 'no',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await pumpPlayer(tester);

    await tester.tap(find.byTooltip('Tonspur'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.text('Deutsch').last);
    await tester.pump();

    expect(engine.audioChoices, ['2']);
  });

  testWidgets('ohne Auswahl steht kein Menü da', (tester) async {
    final series = Directory('${root.path}/Anime/Chainsaw Man')
      ..createSync(recursive: true);
    File(
      '${series.path}/S01E01 - Dog.mkv',
    ).writeAsBytesSync(List.filled(64, 3));

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await player.open(library.library!, library.works.first);
    });
    await pumpPlayer(tester);

    expect(find.byTooltip('Tonspur'), findsNothing);
    expect(find.byTooltip('Untertitel'), findsNothing);
  });

  testWidgets('mehrere Hörbuchdateien heißen Dateien', (tester) async {
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    for (final track in ['01 - Anfang', '02 - Mitte']) {
      File('${work.path}/$track.mp3').writeAsBytesSync(List.filled(64, 1));
    }

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      await player.open(library.library!, library.works.first);
    });
    await pumpPlayer(tester);

    expect(find.text('DATEIEN'), findsOneWidget);
  });
}
