import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Ein neues Werk beginnt damit, dass das alte aufhört.
///
/// Aus dem Betrieb: ein Podcast lief, dann wurde Musik gestartet — Titel und
/// Cover wechselten, gespielt wurde weiter der Podcast. Die Datei war nicht
/// erreichbar, und das Anhalten fehlte.
void main() {
  late Directory root;
  late FundusLibrary library;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-wechsel-');
    for (final show in ['Podcasts/Auf ein Bier', 'Musik/Kraftwerk/Autobahn']) {
      final folder = Directory('${root.path}/$show')
        ..createSync(recursive: true);
      await File('${folder.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    engine = FakeEngine();
    player = PlaybackController(engine: engine, deviceId: 'test-device');
  });

  tearDown(() async {
    player.dispose();
    library.close();
    await root.delete(recursive: true);
  });

  WorkView workOf(String title) => WorkView.fromSummary(
    library.listWorks().firstWhere((work) => work.title == title),
  );

  test('ein unerreichbares Werk hält das laufende an', () async {
    await player.open(library, workOf('Auf ein Bier'));
    engine.emitDuration(const Duration(minutes: 90));
    engine.emitPosition(const Duration(minutes: 8));
    await Future<void>.delayed(Duration.zero);
    expect(engine.playing, isTrue);

    // Dieselbe Bibliothek, aber die Datei ist weg — der Fall, in dem vorher
    // einfach der Podcast weiterlief.
    final album = workOf('Autobahn');
    await File(library.playbackTracks(album.id).single.absolutePath).delete();
    await player.open(library, album);

    expect(player.failure, contains('nicht erreichbar'));
    expect(engine.stopped, isTrue);
    expect(player.isPlaying, isFalse);
    // Und der Stand des Podcasts ist weggeschrieben, nicht dem Album
    // gutgeschrieben.
    final podcast = workOf('Auf ein Bier');
    expect(
      library.loadProgress(podcast.id)!.position.numericValue,
      closeTo(8 * 60, 2),
    );
    expect(library.loadProgress(workOf('Autobahn').id), isNull);
  });

  test('ein Wechsel zu einem erreichbaren Werk spielt das neue', () async {
    await player.open(library, workOf('Auf ein Bier'));
    engine.emitPosition(const Duration(minutes: 3));
    await Future<void>.delayed(Duration.zero);

    await player.open(library, workOf('Autobahn'));

    expect(player.work?.title, 'Autobahn');
    expect(player.currentSource?.title, contains('01'));
    expect(player.failure, isNull);
    expect(engine.playing, isTrue);
  });
}
