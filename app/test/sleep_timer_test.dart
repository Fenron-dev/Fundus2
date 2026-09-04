import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/playback_preference.dart';

import 'playback_controller_test.dart' show FakeEngine;
import 'package:fundus/media/playback_controller.dart';

/// Stopping after a while, and the habits that survive a reinstall.
void main() {
  test('Sprungweiten und Tempo überstehen das Ablegen', () {
    const habits = PlaybackPreference(
      rate: 1.5,
      skipBack: Duration(seconds: 10),
      skipForward: Duration(seconds: 45),
      sleepTimer: Duration(minutes: 15),
      sleepAtChapterEnd: false,
    );

    final read = PlaybackPreference.fromJson(habits.toJson());

    expect(read.rate, 1.5);
    expect(read.skipBack, const Duration(seconds: 10));
    expect(read.skipForward, const Duration(seconds: 45));
    expect(read.sleepTimer, const Duration(minutes: 15));
    expect(read.sleepAtChapterEnd, isFalse);
  });

  test('unsinnige Werte aus einer Datei werden eingefangen', () {
    final wild = PlaybackPreference.fromJson({
      'rate': 99,
      'skip_back': -5,
      'sleep_timer_minutes': 100000,
    });

    // Ein Tempo von 99 macht den Player unbedienbar; eine Datei darf das
    // nicht können.
    expect(wild.rate, 3);
    expect(wild.skipBack.inSeconds, greaterThan(0));
    expect(wild.sleepTimer.inMinutes, lessThanOrEqualTo(480));
  });

  test('der Timer läuft, zeigt die Restzeit und lässt sich abbrechen', () {
    final player = PlaybackController(engine: FakeEngine());
    addTearDown(player.dispose);

    expect(player.sleepRemaining, isNull);

    player.startSleepTimer(const Duration(minutes: 20));
    expect(player.sleepRemaining, isNotNull);
    expect(player.sleepRemaining!.inMinutes, inInclusiveRange(19, 20));

    player.cancelSleepTimer();
    expect(player.sleepRemaining, isNull);
    expect(player.isSleepingAtChapterEnd, isFalse);
  });

  test('ohne Auswahl gilt die eingestellte Dauer', () {
    final player = PlaybackController(engine: FakeEngine())
      ..habits = const PlaybackPreference(sleepTimer: Duration(minutes: 45));
    addTearDown(player.dispose);

    player.startSleepTimer();

    expect(player.sleepRemaining!.inMinutes, inInclusiveRange(44, 45));
  });
}
