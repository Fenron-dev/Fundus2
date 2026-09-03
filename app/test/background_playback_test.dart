import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/background_playback.dart';
import 'package:fundus/media/playback_controller.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// The media session mirrors the player. It is the only thing that keeps an
/// audiobook alive once the window is gone, so what it publishes has to be
/// what is actually playing.
void main() {
  late Directory root;
  late LibraryController library;
  late FakeEngine engine;
  late PlaybackController player;
  late FundusAudioHandler handler;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-session-');
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${work.path}/01 - Anfang.mp3').writeAsBytesSync(List.filled(64, 1));
    File('${work.path}/02 - Mitte.mp3').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
    handler = FundusAudioHandler(player);
  });

  tearDown(() async {
    handler.detach();
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('ohne Werk meldet die Sitzung, dass nichts läuft', () async {
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
  });

  test('das laufende Werk steht in der Sitzung', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();
    await player.open(library.library!, library.works.first);

    final item = handler.mediaItem.value;
    expect(item, isNotNull);
    expect(item!.album, contains('Der Schacht'));
    expect(item.title, contains('01 - Anfang'));

    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.playing, isTrue);
  });

  test('die Knöpfe der Sitzung steuern denselben Player', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();
    await player.open(library.library!, library.works.first);

    await handler.pause();
    expect(engine.playing, isFalse);

    await handler.play();
    expect(engine.playing, isTrue);

    await handler.seek(const Duration(minutes: 3));
    expect(engine.seeks.last, const Duration(minutes: 3));

    await handler.skipToNext();
    expect(player.trackIndex, 1);

    await handler.skipToPrevious();
    expect(player.trackIndex, 0);
  });

  test('die Sitzung folgt einer Pause, die woanders ausgelöst wurde', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();
    await player.open(library.library!, library.works.first);
    expect(handler.playbackState.value.playing, isTrue);

    await player.playOrPause();
    // Der Zustand kommt aus dem Strom der Engine, nicht aus dem Knopf.
    engine.emitPlaying(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(handler.playbackState.value.playing, isFalse);
  });
}
