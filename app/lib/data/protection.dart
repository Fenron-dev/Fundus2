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

  /// Visible in lists, but the covers are veiled until unlocked.
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

  ProtectionMode get mode => settings.protectionMode;

  /// Whether this session has been unlocked. Never persisted: closing the app
  /// locks it again, which is the whole point.
  bool get isUnlocked => _unlocked || mode == ProtectionMode.off;

  bool get hasPin => settings.protectionPin.isNotEmpty;

  /// Whether a work must not appear at all right now.
  bool hides(WorkView work) =>
      mode == ProtectionMode.hide && work.summary.isHhh && !isUnlocked;

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
    await settings.setProtectionPin('$salt:${_digest(digits, salt)}');
    _unlocked = true;
    notifyListeners();
  }

  /// Opens the shelf for this session.
  ///
  /// A wrong PIN is answered with false rather than an exception: it is the
  /// expected case, not a fault.
  bool unlock(String pin) {
    final stored = settings.protectionPin;
    if (stored.isEmpty) return false;
    final parts = stored.split(':');
    if (parts.length != 2) return false;
    if (_digest(pin.trim(), parts.first) != parts.last) return false;
    _unlocked = true;
    notifyListeners();
    return true;
  }

  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    notifyListeners();
  }

  static String _salt() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(12, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  /// Salted, so the same PIN on two devices does not produce the same string,
  /// and so a file full of digests says nothing about the digits.
  static String _digest(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt|$pin')).toString();
}
