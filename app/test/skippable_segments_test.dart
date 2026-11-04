import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:fundus/media/playback_preference.dart';
import 'package:fundus/media/skippable_segments.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine, waitForPlayback;

/// An opening heard once is enough. Where the file itself marks it, the
/// player offers to skip it — and only there.
void main() {
  group('reading chapter marks', () {
    test('openings, recaps and credits are found by name', () {
      final segments = skippableSegments(const [
        FileChapter(title: 'Previously', start: Duration.zero),
        FileChapter(title: 'Opening', start: Duration(seconds: 40)),
        FileChapter(title: 'Teil A', start: Duration(seconds: 130)),
        FileChapter(title: 'Ending', start: Duration(minutes: 21)),
        FileChapter(
          title: 'Preview',
          start: Duration(minutes: 22, seconds: 30),
        ),
      ], duration: const Duration(minutes: 23));
      expect(segments.map((segment) => segment.kind), [
        SkippableKind.recap,
        SkippableKind.intro,
        SkippableKind.credits,
        SkippableKind.credits,
      ]);
      expect(segments[1].start, const Duration(seconds: 40));
      expect(segments[1].end, const Duration(seconds: 130));
    });

    test('a chapter that only sounds like one is left alone', () {
      final segments = skippableSegments(const [
        FileChapter(title: 'Introduction to Chemistry', start: Duration.zero),
        // Twenty minutes is not an intro, whatever it is called.
        FileChapter(title: 'Intro', start: Duration(minutes: 1)),
        FileChapter(title: 'Hauptteil', start: Duration(minutes: 21)),
      ], duration: const Duration(minutes: 40));
      expect(segments, isEmpty);
    });
  });

  group('player', () {
    late Directory root;
    late FundusLibrary library;
    late FakeEngine engine;
    late PlaybackController controller;
    late WorkView work;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-skip-');
      final film = Directory('${root.path}/Filme/Nordwind')
        ..createSync(recursive: true);
      File('${film.path}/Nordwind.mkv').writeAsBytesSync(List.filled(64, 1));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      work = WorkView.fromSummary(library.listWorks().single);
      engine = FakeEngine()
        ..chapters = const [
          FileChapter(title: 'Kapitel 1', start: Duration.zero),
          FileChapter(title: 'Opening', start: Duration(seconds: 30)),
          FileChapter(title: 'Kapitel 2', start: Duration(seconds: 120)),
        ];
      controller = PlaybackController(engine: engine, deviceId: 'test');
    });

    tearDown(() async {
      controller.dispose();
      await library.shutdown();
      await root.delete(recursive: true);
    });

    test('the button appears inside the opening and skips it', () async {
      await controller.open(library, work);
      engine.emitDuration(const Duration(minutes: 20));
      await waitForPlayback(controller, () => controller.isPlaying);
      await Future<void>.delayed(Duration.zero);

      engine.emitPosition(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(controller.activeSegment, isNull);

      engine.emitPosition(const Duration(seconds: 45));
      await Future<void>.delayed(Duration.zero);
      expect(controller.activeSegment?.kind, SkippableKind.intro);
      // Not on its own: the setting is off.
      expect(engine.seeks, isNot(contains(const Duration(seconds: 120))));

      await controller.skipSegment();
      expect(engine.seeks.last, const Duration(seconds: 120));
    });

    test('with the setting on, the opening is skipped once', () async {
      controller.habits = const PlaybackPreference(skipIntros: true);
      await controller.open(library, work);
      engine.emitDuration(const Duration(minutes: 20));
      await Future<void>.delayed(Duration.zero);

      engine.emitPosition(const Duration(seconds: 31));
      await Future<void>.delayed(Duration.zero);
      expect(engine.seeks.last, const Duration(seconds: 120));

      // Seeking back into it means wanting to see it.
      final before = engine.seeks.length;
      engine.emitPosition(const Duration(seconds: 40));
      await Future<void>.delayed(Duration.zero);
      expect(engine.seeks.length, before);
    });

    test('night mode reaches the engine when it changes', () async {
      controller.habits = const PlaybackPreference(nightMode: true);
      controller.habits = const PlaybackPreference(nightMode: true);
      controller.habits = const PlaybackPreference();
      expect(engine.nightModes, [true, false]);
    });
  });
}
