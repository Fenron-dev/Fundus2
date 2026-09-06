import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Wiedergabe, die abreißt, fängt von selbst wieder an — und „abspielen"
/// heißt immer, dass etwas spielt.
///
/// Aus dem Betrieb: die Musik hörte mitten im Stück auf, und weiter ging es
/// nur noch über „Fortsetzen" auf dem Dashboard.
void main() {
  late Directory root;
  late FundusLibrary library;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-abriss-');
    final folder = Directory('${root.path}/Musik/Kraftwerk/Autobahn')
      ..createSync(recursive: true);
    await File('${folder.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    // Ein zweites Album, das wirklich zwei Titel hat.
    final pair = Directory('${root.path}/Musik/Kraftwerk/Doppel')
      ..createSync(recursive: true);
    for (final track in ['01', '02']) {
      await File('${pair.path}/$track.mp3').writeAsBytes(List.filled(64, 1));
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

  WorkView workNamed(String title) => WorkView.fromSummary(
    library.listWorks().firstWhere((work) => work.title == title),
  );

  WorkView album() => workNamed('Autobahn');
  WorkView twoTracks() => workNamed('Doppel');

  test('ein Abriss mitten im Stück setzt dieselbe Stelle wieder auf', () async {
    await player.open(library, album());
    engine.emitDuration(const Duration(minutes: 50));
    engine.emitPosition(const Duration(minutes: 12));
    await Future<void>.delayed(Duration.zero);
    expect(engine.opened, hasLength(1));

    // mpv meldet ein Ende, das keines sein kann: 38 Minuten fehlen.
    engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(engine.opened, hasLength(2));
    expect(engine.starts.last, const Duration(minutes: 12));
    expect(engine.playing, isTrue);
    expect(player.failure, isNull);
  });

  test('ein echtes Ende bleibt ein Ende', () async {
    await player.open(library, album());
    engine.emitDuration(const Duration(minutes: 50));
    engine.emitPosition(const Duration(minutes: 50));
    await Future<void>.delayed(Duration.zero);

    engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(engine.opened, hasLength(1));
    expect(player.hasStopped, isTrue);
  });

  test('nach dem Ende fängt abspielen wieder an', () async {
    await player.open(library, album());
    engine.emitDuration(const Duration(minutes: 50));
    engine.emitPosition(const Duration(minutes: 50));
    await Future<void>.delayed(Duration.zero);
    engine.emitCompleted();
    engine.emitPlaying(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(player.isPlaying, isFalse);

    // Der Druck, der vorher ins Leere ging.
    await player.playOrPause();

    expect(engine.opened, hasLength(2));
    expect(engine.playing, isTrue);
  });

  test('eine Datei, die wieder da ist, spielt auf Knopfdruck', () async {
    final track = File(library.playbackTracks(album().id).single.absolutePath);
    final bytes = await track.readAsBytes();
    await track.delete();

    await player.open(library, album());
    expect(player.failure, contains('nicht erreichbar'));

    await track.writeAsBytes(bytes);
    await player.playOrPause();

    expect(player.failure, isNull);
    expect(engine.playing, isTrue);
  });

  /// Aus dem Betrieb: ein Album mit fünfzig Titeln, das Handy ging in die
  /// Sperre, das Lied spielte zu Ende — und das nächste kam nicht mehr.
  test('nach dem Lied kommt das nächste', () async {
    await player.open(library, twoTracks());
    engine.emitDuration(const Duration(minutes: 4));
    engine.emitPosition(const Duration(minutes: 4));
    await Future<void>.delayed(Duration.zero);

    engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(player.trackIndex, 1);
    expect(player.currentSource?.title, contains('02'));
    expect(engine.playing, isTrue);
  });

  test(
    'kommt die nächste Datei nicht, steht der Stand trotzdem richtig',
    () async {
      await player.open(library, twoTracks());
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitPosition(const Duration(minutes: 4));
      await Future<void>.delayed(Duration.zero);

      // Die zweite Datei ist weg, wenn die erste endet.
      final second = File(
        library.playbackTracks(twoTracks().id)[1].absolutePath,
      );
      final bytes = await second.readAsBytes();
      await second.delete();
      engine.emitCompleted();
      // Gefragt wird zweimal, mit einer Pause dazwischen.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(player.failure, contains('nicht erreichbar'));
      expect(player.trackIndex, 1);
      // Und nicht mehr der Stand des vorigen Titels.
      expect(player.position, Duration.zero);

      // Ist sie wieder da, genügt ein Druck.
      await second.writeAsBytes(bytes);
      await player.playOrPause();

      expect(player.failure, isNull);
      expect(player.currentSource?.title, contains('02'));
      expect(engine.playing, isTrue);
    },
  );
}
