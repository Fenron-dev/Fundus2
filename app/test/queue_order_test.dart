import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_preference.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Shuffle and repeat.
///
/// The rules are the ones every player has, and they are worth pinning
/// because each of them is a place where a queue quietly does the wrong
/// thing: „weiter" that plays the same track again, „zurück" that cannot say
/// what was played, an album that stops when it was asked to loop.
Future<(FundusLibrary, WorkView)> buildAlbum(Directory root) async {
  final album = Directory('${root.path}/Musik/Genesis/Invisible Touch')
    ..createSync(recursive: true);
  for (var index = 1; index <= 4; index++) {
    await File(
      '${album.path}/0$index - Titel $index.mp3',
    ).writeAsBytes(List.filled(64, index));
  }
  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  final summary = library.listWorks().firstWhere(
    (entry) => entry.fileCount > 0,
  );
  return (library, WorkView.fromSummary(summary));
}

void main() {
  late Directory root;
  late FundusLibrary library;
  late WorkView work;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-queue-');
    (library, work) = await buildAlbum(root);
    engine = FakeEngine();
    player = PlaybackController(engine: engine, deviceId: 'test-device');
  });

  tearDown(() async {
    player.dispose();
    library.close();
    await root.delete(recursive: true);
  });

  test('ein Album landet unter Musik, nicht bei den Hörbüchern', () {
    expect(library.listWorks().first.kind, 'album');
  });

  test('ohne Wiederholung endet das Album am letzten Titel', () async {
    await player.open(library, work);
    for (var step = 0; step < 3; step++) {
      await player.next();
    }
    expect(player.trackIndex, 3);

    await player.next();

    expect(player.trackIndex, 3, reason: 'es geht nicht weiter');
    expect(engine.playing, isFalse);
  });

  test('„alles wiederholen" fängt wieder vorn an', () async {
    await player.open(library, work);
    await player.cycleRepeat();
    expect(player.repeatMode, RepeatMode.all);
    for (var step = 0; step < 3; step++) {
      await player.next();
    }

    await player.next();

    expect(player.trackIndex, 0);
    expect(engine.playing, isTrue);
  });

  test(
    '„Titel wiederholen" gilt am Ende, nicht für die Weiter-Taste',
    () async {
      await player.open(library, work);
      await player.cycleRepeat();
      await player.cycleRepeat();
      expect(player.repeatMode, RepeatMode.one);

      // Von allein: derselbe Titel noch einmal.
      engine.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(player.trackIndex, 0);

      // Gedrückt: der nächste.
      await player.next();
      expect(player.trackIndex, 1);
    },
  );

  test(
    'zufällig heißt eine Reihenfolge, nicht jedes Mal neu würfeln',
    () async {
      await player.open(library, work);
      await player.setShuffle(true);
      expect(player.isShuffling, isTrue);

      final played = <int>[player.trackIndex];
      for (var step = 0; step < 3; step++) {
        await player.next();
        played.add(player.trackIndex);
      }

      expect(played.toSet(), hasLength(4), reason: 'jeder Titel genau einmal');
      expect(played.first, 0, reason: 'der laufende Titel bleibt der laufende');

      // Und zurück führt dahin, wo es herkam.
      await player.previous();
      expect(player.trackIndex, played[2]);
    },
  );

  test('ohne Zufall ist die Reihenfolge wieder die des Albums', () async {
    await player.open(library, work);
    await player.setShuffle(true);
    await player.setShuffle(false);

    await player.next();

    expect(player.trackIndex, 1);
  });

  test('die Einstellung übersteht das Schreiben und Lesen', () {
    const habits = PlaybackPreference(shuffle: true, repeat: RepeatMode.one);

    final read = PlaybackPreference.fromJson(habits.toJson());

    expect(read.shuffle, isTrue);
    expect(read.repeat, RepeatMode.one);
    expect(const PlaybackPreference().repeat, RepeatMode.none);
  });
}
