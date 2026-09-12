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
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  static const _kdfIterations = 100000;

  ProtectionMode get mode => settings.protectionMode;

  /// Whether this session has been unlocked. Never persisted: closing the app
  /// locks it again, which is the whole point.
  bool get isUnlocked => _unlocked || mode == ProtectionMode.off;

  bool get hasPin => settings.protectionPin.isNotEmpty;

  /// Whether a work must not appear at all right now.
  bool hides(WorkView work) =>
      mode != ProtectionMode.off && work.summary.isHhh && !isUnlocked;

  /// Whether a work's picture is veiled — it is listed, but not shown.
  bool veils(WorkView work) =>
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
    await settings.setProtectionPin(
      'v2:$_kdfIterations:$salt:${_derive(digits, salt, _kdfIterations)}',
    );
    _unlocked = true;
    notifyListeners();
  }

  /// Opens the shelf for this session.
  ///
  /// A wrong PIN is answered with false rather than an exception: it is the
  /// expected case, not a fault.
  bool unlock(String pin) {
    final now = DateTime.now();
    final lockedUntil = _lockedUntil;
    if (lockedUntil != null && now.isBefore(lockedUntil)) return false;
    _lockedUntil = null;
    final stored = settings.protectionPin;
    if (stored.isEmpty) return _failed();
    final parts = stored.split(':');
    var valid = false;
    if (parts.length == 4 && parts.first == 'v2') {
      final iterations = int.tryParse(parts[1]);
      if (iterations != null && iterations >= 10000 && iterations <= 1000000) {
        valid = _constantTimeEquals(
          _derive(pin.trim(), parts[2], iterations),
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
    _failedAttempts = 0;
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
  void unlockAuthenticatedSession() {
    if (mode == ProtectionMode.off || _unlocked) return;
    _failedAttempts = 0;
    _lockedUntil = null;
    _unlocked = true;
    notifyListeners();
  }

  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    notifyListeners();
  }

  bool _failed() {
    _failedAttempts++;
    if (_failedAttempts >= 5) {
      _failedAttempts = 0;
      _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
    }
    return false;
  }

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
