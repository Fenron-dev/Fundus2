import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_preference.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// The end of an episode.
///
/// A series is watched one after another, so the next one starts by itself —
/// but it says so first, and stopping it is one tap. A film has nothing to
/// decide and gets no card at all.
void main() {
  test('ohne nächste Folge gibt es nichts zu fragen', () {
    final player = PlaybackController(engine: FakeEngine());
    addTearDown(player.dispose);

    expect(player.isBetweenEpisodes, isFalse);
    expect(player.nextEpisodeIn, isNull);
    expect(player.nextEpisodeTitle, isNull);
  });

  test('die Wartezeit ist eine Einstellung, keine feste Zahl', () {
    const habits = PlaybackPreference(
      autoplayNext: true,
      autoplayDelay: Duration(seconds: 12),
    );

    final read = PlaybackPreference.fromJson(habits.toJson());

    expect(read.autoplayNext, isTrue);
    expect(read.autoplayDelay, const Duration(seconds: 12));
  });

  test('abgeschaltet heißt abgeschaltet, auch aus einer Datei gelesen', () {
    final off = PlaybackPreference.fromJson({'autoplay_next': false});

    expect(off.autoplayNext, isFalse);
    // Und die Vorgabe bleibt an: dafür ist eine Serie da.
    expect(const PlaybackPreference().autoplayNext, isTrue);
  });
}
