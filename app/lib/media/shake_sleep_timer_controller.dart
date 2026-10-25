import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'playback_controller.dart';

/// Listens for a deliberate two-impulse shake only while a sleep timer is on.
/// No sensor polling or battery use is incurred during ordinary browsing.
final class ShakeSleepTimerController {
  ShakeSleepTimerController(this._player) {
    _player.addListener(_sync);
    _sync();
  }

  final PlaybackController _player;
  StreamSubscription<UserAccelerometerEvent>? _subscription;
  DateTime? _firstImpulse;
  DateTime? _lastAcceptedShake;
  bool _armed = true;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final timerIsActive =
        _player.sleepRemaining != null || _player.isSleepingAtChapterEnd;
    final shouldListen =
        !kIsWeb &&
        Platform.isAndroid &&
        _player.habits.shakeToExtendSleepTimer &&
        timerIsActive;
    if (shouldListen && _subscription == null) {
      _subscription = userAccelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 100),
      ).listen(_onMotion, onError: _onSensorError, cancelOnError: true);
    } else if (!shouldListen && _subscription != null) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _firstImpulse = null;
      _armed = true;
    }
  }

  void _onMotion(UserAccelerometerEvent event) {
    final magnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    final now = DateTime.now();
    if (magnitude < 7) _armed = true;
    if (magnitude < 14 || !_armed) return;
    _armed = false;

    final first = _firstImpulse;
    if (first == null || now.difference(first) > const Duration(seconds: 1)) {
      _firstImpulse = now;
      return;
    }
    _firstImpulse = null;
    final accepted = _lastAcceptedShake;
    if (accepted != null &&
        now.difference(accepted) < const Duration(seconds: 8)) {
      return;
    }
    _lastAcceptedShake = now;
    _player.extendSleepTimer(const Duration(minutes: 5));
  }

  void _onSensorError(Object error) {
    // A missing or unavailable sensor must never affect audio playback.
    debugPrint('Schüttelfunktion nicht verfügbar: $error');
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _player.removeListener(_sync);
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
