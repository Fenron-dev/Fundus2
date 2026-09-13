import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../app/app_settings.dart';
import 'work_view.dart';

/// How much of the protected shelf is visible.
enum ProtectionMode {
  /// Nothing is hidden. The default: a library that hides things by default
  /// would hide them from the person who put them there.
  off('Aus', 'Alles ist sichtbar.'),

  /// Legacy value from previews that only veiled covers. It is read as
  /// [hide] by current settings so a closed lock has one unambiguous meaning.
  blur('Unscharf', 'Sichtbar, aber die Vorschau bleibt verdeckt.'),

  /// Not in lists, not in search, not in „Fortsetzen".
  hide('Ausblenden', 'Erscheint nirgends, bis entsperrt wird.');

  const ProtectionMode(this.label, this.description);

  final String label;
  final String description;
}

/// The protected shelf, and who gets to see it.
///
/// Two things are deliberately separate: whether protected works are hidden,
/// and whether this session has been unlocked. Hiding is a setting; unlocking
/// is something that happens once and lapses when the app closes — a lock
/// that stays open forever is a decoration.
///
/// The PIN lives with the device and never in the vault. A vault folder is
/// shared by definition; a lock whose key travels in the thing it locks is
/// not a lock. It is stored as a salted hash, so the settings file does not
/// hold the digits either.
class ProtectionController extends ChangeNotifier {
  ProtectionController({required this.settings});

  final AppSettings settings;

  bool _unlocked = false;

  static const _kdfIterations = 100000;

  ProtectionMode get mode => settings.protectionMode;

  /// Whether this session has been unlocked. Never persisted: closing the app
  /// locks it again, which is the whole point.
  bool get isUnlocked => _unlocked || mode == ProtectionMode.off;

  bool get hasPin => settings.protectionPin.isNotEmpty;

  /// Whether a work must not appear at all right now.
  ///
  /// There is one answer, not two. A preview build also veiled pictures while
  /// still listing the work; that mode is gone, and a second method saying the
  /// same thing only invites the two to drift apart.
  bool hides(WorkView work) =>
      mode != ProtectionMode.off && work.summary.isHhh && !isUnlocked;

  Future<void> setMode(ProtectionMode value) async {
    await settings.setProtectionMode(value);
    if (value == ProtectionMode.off) _unlocked = false;
    notifyListeners();
  }

  /// Sets or changes the PIN. An empty value removes it, which also means
  /// there is nothing left to unlock.
  Future<void> setPin(String pin) async {
    final digits = pin.trim();
    if (digits.isEmpty) {
      await settings.setProtectionPin('');
      _unlocked = false;
      notifyListeners();
      return;
    }
    final salt = _salt();
    final digest = await _deriveOffThread(digits, salt, _kdfIterations);
    await settings.setProtectionPin('v2:$_kdfIterations:$salt:$digest');
    await _clearAttempts();
    _unlocked = true;
    notifyListeners();
  }

  /// Opens the shelf for this session.
  ///
  /// A wrong PIN is answered with false rather than an exception: it is the
  /// expected case, not a fault.
  /// Whether the shelf is barred right now, and until when.
  ///
  /// Survives a restart, because a limit that a restart lifts is no limit at
  /// all against a four-digit PIN.
  DateTime? get lockedUntil {
    final until = settings.protectionLockedUntil;
    if (until == null) return null;
    return DateTime.now().isBefore(until) ? until : null;
  }

  bool get isLockedOut => lockedUntil != null;

  Future<bool> unlock(String pin) async {
    if (isLockedOut) return false;
    final stored = settings.protectionPin;
    if (stored.isEmpty) return _failed();
    final parts = stored.split(':');
    var valid = false;
    if (parts.length == 4 && parts.first == 'v2') {
      final iterations = int.tryParse(parts[1]);
      if (iterations != null && iterations >= 10000 && iterations <= 1000000) {
        valid = _constantTimeEquals(
          await _deriveOffThread(pin.trim(), parts[2], iterations),
          parts[3],
        );
      }
    } else if (parts.length == 2) {
      valid = _constantTimeEquals(
        _legacyDigest(pin.trim(), parts[0]),
        parts[1],
      );
    }
    if (!valid) return _failed();
    await _clearAttempts();
    _unlocked = true;
    notifyListeners();
    return true;
  }

  /// Opens the protected shelf after the operating system has authenticated
  /// the person with biometrics or the device credential.
  ///
  /// The caller must only invoke this after a successful platform prompt.
  /// Nothing is persisted: just like the Fundus PIN, this grant belongs to
  /// the current process and disappears when the app is closed.
  Future<void> unlockAuthenticatedSession() async {
    if (mode == ProtectionMode.off || _unlocked) return;
    await _clearAttempts();
    _unlocked = true;
    notifyListeners();
  }

  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    notifyListeners();
  }

  /// Counts a wrong attempt and bars the shelf once there have been enough.
  ///
  /// The counter is *not* cleared when the bar goes up — clearing it handed
  /// out five fresh attempts the moment the bar expired. Only a successful
  /// unlock clears it, and the wait grows with every further attempt.
  Future<bool> _failed() async {
    final attempts = settings.protectionFailedAttempts + 1;
    await settings.setProtectionLockout(
      failedAttempts: attempts,
      lockedUntil: attempts >= _attemptsBeforeLockout
          ? DateTime.now().add(_lockoutFor(attempts))
          : null,
    );
    notifyListeners();
    return false;
  }

  static const _attemptsBeforeLockout = 5;

  /// Thirty seconds, then a minute, then four, capped at an hour.
  static Duration _lockoutFor(int attempts) {
    final steps = attempts - _attemptsBeforeLockout;
    final seconds = 30 * (1 << (steps > 7 ? 7 : steps));
    return Duration(seconds: seconds > 3600 ? 3600 : seconds);
  }

  Future<void> _clearAttempts() =>
      settings.setProtectionLockout(failedAttempts: 0);

  static String _salt() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(12, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  /// Legacy verifier retained so existing installations can still unlock once
  /// and then migrate the PIN on the next explicit change.
  static String _legacyDigest(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt|$pin')).toString();

  /// Runs the derivation off the interface thread.
  ///
  /// A hundred thousand HMAC rounds are a noticeable pause on a phone, and the
  /// interface would sit frozen through every unlock and every PIN change.
  static Future<String> _deriveOffThread(
    String pin,
    String salt,
    int iterations,
  ) => compute(_deriveMessage, (pin, salt, iterations));

  static String _deriveMessage((String, String, int) message) =>
      _derive(message.$1, message.$2, message.$3);

  /// PBKDF2-HMAC-SHA256 makes offline guessing substantially more expensive
  /// than the former single SHA-256 digest while keeping the settings format
  /// portable across platforms.
  static String _derive(String pin, String salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    final message = <int>[...utf8.encode(salt), 0, 0, 0, 1];
    var block = hmac.convert(message).bytes;
    final result = List<int>.from(block);
    for (var round = 1; round < iterations; round++) {
      block = hmac.convert(block).bytes;
      for (var index = 0; index < result.length; index++) {
        result[index] ^= block[index];
      }
    }
    return result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }
}
