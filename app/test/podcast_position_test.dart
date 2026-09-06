import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Jede Folge behält ihre eigene Stelle.
///
/// Ein Hörbuch wird von vorn nach hinten gehört, da genügt ein Stand für das
/// ganze Werk. Eine Podcast-Folge steht für sich: eine Stunde davon, dann
/// eine andere, dann zurück — mit nur einem Stand pro Werk fängt die erste
/// jedes Mal wieder vorn an.
void main() {
  late Directory root;
  late FundusLibrary library;
  late WorkView work;
  late List<LibraryPlaybackTrack> tracks;
  late FakeEngine engine;
  late PlaybackController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-podcast-');
    final folder = Directory('${root.path}/Podcasts/Auf ein Bier')
      ..createSync(recursive: true);
    for (final name in ['Folge 1.mp3', 'Folge 2.mp3']) {
      await File('${folder.path}/$name').writeAsBytes(List.filled(64, 1));
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    work = WorkView.fromSummary(library.listWorks().single);
    expect(work.mediaType?.id, 'podcast');
    tracks = library.playbackTracks(work.id);
    engine = FakeEngine();
    controller = PlaybackController(engine: engine, deviceId: 'test-device');
  });

  tearDown(() async {
    controller.dispose();
    library.close();
    await root.delete(recursive: true);
  });

  test('eine Folge fängt dort an, wo sie verlassen wurde', () async {
    await controller.open(library, work, startAt: tracks.first.fileId);
    engine.emitDuration(const Duration(minutes: 90));
    engine.emitPosition(const Duration(minutes: 37));
    await Future<void>.delayed(Duration.zero);
    controller.saveProgress();

    // Dazwischen die andere Folge, wie im richtigen Leben.
    await controller.open(library, work, startAt: tracks.last.fileId);
    engine.emitDuration(const Duration(minutes: 60));
    engine.emitPosition(const Duration(minutes: 4));
    await Future<void>.delayed(Duration.zero);
    controller.saveProgress();

    final again = FakeEngine();
    final resumed = PlaybackController(engine: again, deviceId: 'test-device');
    addTearDown(resumed.dispose);
    await resumed.open(
      library,
      work,
      startAt: tracks.first.fileId,
      autoplay: false,
    );

    expect(resumed.trackIndex, 0);
    expect(again.starts.single.inMinutes, 37);
  });

  test('ein Sprung zur anderen Folge hält beide Stände fest', () async {
    await controller.open(library, work, startAt: tracks.first.fileId);
    engine.emitDuration(const Duration(minutes: 90));
    engine.emitPosition(const Duration(minutes: 22));
    await Future<void>.delayed(Duration.zero);

    await controller.jumpToTrack(1);

    // Der Stand der ersten Folge steht fest, bevor gewechselt wird.
    final stored = library.filePositions(work.id);
    expect(stored[tracks.first.fileId]!.position, closeTo(22 * 60, 2));

    engine.emitDuration(const Duration(minutes: 60));
    engine.emitPosition(const Duration(minutes: 9));
    await Future<void>.delayed(Duration.zero);
    controller.saveProgress();

    // Und zurück: die erste Folge liegt noch dort, wo sie stand.
    await controller.jumpToTrack(0);
    expect(engine.starts.last.inMinutes, 22);
  });

  test('eine zu Ende gehörte Folge fängt wieder von vorn an', () async {
    await controller.open(library, work, startAt: tracks.first.fileId);
    engine.emitDuration(const Duration(minutes: 50));
    engine.emitPosition(const Duration(minutes: 49, seconds: 55));
    await Future<void>.delayed(Duration.zero);
    controller.saveProgress();

    final again = FakeEngine();
    final resumed = PlaybackController(engine: again, deviceId: 'test-device');
    addTearDown(resumed.dispose);
    await resumed.open(
      library,
      work,
      startAt: tracks.first.fileId,
      autoplay: false,
    );

    expect(again.starts.single, Duration.zero);
  });

  test('ein Hörbuch führt weiterhin einen Stand für das ganze Werk', () async {
    final other = await Directory.systemTemp.createTemp('fundus-hoerbuch-');
    addTearDown(() => other.delete(recursive: true));
    final folder = Directory('${other.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    for (final name in ['01.mp3', '02.mp3']) {
      await File('${folder.path}/$name').writeAsBytes(List.filled(64, 1));
    }
    final vault = await FundusLibrary.create(other);
    addTearDown(vault.close);
    await vault.index().drain<void>();
    final book = WorkView.fromSummary(vault.listWorks().single);
    final files = vault.playbackTracks(book.id);

    final bookEngine = FakeEngine();
    final player = PlaybackController(engine: bookEngine);
    addTearDown(player.dispose);
    await player.open(vault, book, startAt: files.first.fileId);
    bookEngine.emitDuration(const Duration(minutes: 40));
    bookEngine.emitPosition(const Duration(minutes: 12));
    await Future<void>.delayed(Duration.zero);
    player.saveProgress();

    expect(vault.filePositions(book.id), isEmpty);
    expect(vault.loadProgress(book.id)!.position.numericValue, closeTo(720, 2));
  });
}
