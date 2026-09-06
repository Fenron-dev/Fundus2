import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:fundus/media/track_preference.dart';
import 'package:fundus_core/fundus_core.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// mpv meldet seine Spuren nach und nach.
///
/// Aus dem Betrieb: „Ton, am liebsten: Deutsch" stand da, und der Film lief
/// trotzdem auf Englisch. Entschieden wurde, bevor die deutsche Spur
/// überhaupt gemeldet war.
void main() {
  late Directory root;
  late FundusLibrary library;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-tonspur-');
    final film = Directory('${root.path}/Filme/About Time (2013)')
      ..createSync(recursive: true);
    await File(
      '${film.path}/About Time (2013).mkv',
    ).writeAsBytes(List.filled(64, 1));
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    engine = FakeEngine();
    player = PlaybackController(engine: engine, deviceId: 'test-device')
      ..preference = const TrackPreference(audioWishes: ['de']);
  });

  tearDown(() async {
    player.dispose();
    library.close();
    await root.delete(recursive: true);
  });

  WorkView film() => WorkView.fromSummary(library.listWorks().single);

  test('eine später gemeldete Spur wird noch gewählt', () async {
    await player.open(library, film());

    // Erste Meldung: nur Englisch, mehr weiß mpv noch nicht.
    engine.emitTracks(
      const MediaTracks(
        audio: [MediaTrackOption(id: '1', label: 'Englisch', language: 'eng')],
        selectedAudioId: '1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.audioChoices, isEmpty);

    // Und kurz darauf die ganze Wahrheit.
    engine.emitTracks(
      const MediaTracks(
        audio: [
          MediaTrackOption(id: '1', label: 'Englisch', language: 'eng'),
          MediaTrackOption(id: '2', label: 'Deutsch', language: 'ger'),
        ],
        selectedAudioId: '1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.audioChoices, ['2']);
  });

  test('eine Wahl von Hand hält den Wunsch an', () async {
    await player.open(library, film());
    await player.selectAudioTrack('1');

    engine.emitTracks(
      const MediaTracks(
        audio: [
          MediaTrackOption(id: '1', label: 'Englisch', language: 'eng'),
          MediaTrackOption(id: '2', label: 'Deutsch', language: 'ger'),
        ],
        selectedAudioId: '1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Nur die Wahl von Hand, kein Umschalten hinterher.
    expect(engine.audioChoices, ['1']);
  });

  test('was schon läuft, wird nicht noch einmal gewählt', () async {
    await player.open(library, film());
    for (var round = 0; round < 3; round++) {
      engine.emitTracks(
        const MediaTracks(
          audio: [
            MediaTrackOption(id: '1', label: 'Englisch', language: 'eng'),
            MediaTrackOption(id: '2', label: 'Deutsch', language: 'ger'),
          ],
          selectedAudioId: '2',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(engine.audioChoices, isEmpty);
  });
}
