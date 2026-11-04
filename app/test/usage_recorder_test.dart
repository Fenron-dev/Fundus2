import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus/media/text_reader_controller.dart';
import 'package:fundus/media/usage_recorder.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine, waitForPlayback;

/// Listening time becomes a play event, a fumble does not.
void main() {
  late Directory root;
  late FundusLibrary library;
  late WorkView work;
  late FakeEngine engine;
  late PlaybackController player;
  late ReaderController reader;
  late TextReaderController textReader;
  late UsageRecorder recorder;
  var now = DateTime(2026, 5, 1, 20);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-usage-');
    final book = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${book.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    work = WorkView.fromSummary(library.listWorks().single);
    engine = FakeEngine();
    player = PlaybackController(engine: engine, deviceId: 'phone');
    reader = ReaderController(deviceId: 'phone');
    textReader = TextReaderController(deviceId: 'phone');
    now = DateTime(2026, 5, 1, 20);
    recorder = UsageRecorder(
      player: player,
      reader: reader,
      textReader: textReader,
      library: () => library,
      deviceId: 'phone',
      clock: () => now,
    )..attach();
  });

  tearDown(() async {
    recorder.detach();
    player.dispose();
    reader.dispose();
    textReader.dispose();
    await library.shutdown();
    await root.delete(recursive: true);
  });

  int recordedSeconds() => library
      .usageSummary(from: DateTime(2026), until: DateTime(2027))
      .totalSeconds;

  test('time spent playing is written down when playback stops', () async {
    await player.open(library, work);
    engine.emitPlaying(true);
    await waitForPlayback(player, () => player.isPlaying);

    now = now.add(const Duration(minutes: 25));
    engine.emitPlaying(false);
    await waitForPlayback(player, () => !player.isPlaying);
    recorder.flush();

    expect(recordedSeconds(), 25 * 60);
  });

  test('a few seconds are not a session', () async {
    await player.open(library, work);
    engine.emitPlaying(true);
    await waitForPlayback(player, () => player.isPlaying);
    now = now.add(const Duration(seconds: 10));
    engine.emitPlaying(false);
    await waitForPlayback(player, () => !player.isPlaying);
    recorder.flush();

    expect(recordedSeconds(), 0);
  });

  test('a long session is saved in parts and nothing counts twice', () async {
    await player.open(library, work);
    engine.emitPlaying(true);
    await waitForPlayback(player, () => player.isPlaying);
    now = now.add(const Duration(minutes: 10));
    recorder.flush(partial: true);
    now = now.add(const Duration(minutes: 5));
    engine.emitPlaying(false);
    await waitForPlayback(player, () => !player.isPlaying);
    recorder.flush();

    expect(recordedSeconds(), 15 * 60);
  });
}
