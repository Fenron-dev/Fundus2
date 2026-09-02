import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Everything this device remembers on its own.
///
/// Two kinds of state are deliberately kept apart. What lives here is bound to
/// the installation — window layout, which vaults were opened, and above all
/// the device *identity*, which must never travel in a vault: a copied vault
/// would otherwise clone it and two devices would report the same id.
///
/// Reader and player settings do **not** live here. They go into the vault's
/// `_fundus/devices/` directory, because reinstalling the app must not cost
/// them again — see `DeviceProfile` in the core package.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._file, this._values, {bool ephemeral = false})
    : _ephemeral = ephemeral;

  static const fileName = 'device.json';

  final File _file;

  /// Tests and previews keep their settings in memory; writing them would only
  /// leave files behind.
  final bool _ephemeral;
  Map<String, Object?> _values;

  static Future<AppSettings> load() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, fileName));
    var values = <String, Object?>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          values = Map<String, Object?>.from(decoded.cast<Object?, Object?>());
        }
      } on FormatException {
        // A damaged settings file costs preferences, never a start-up.
      } on FileSystemException {
        // Same.
      }
    }
    final settings = AppSettings._(file, values);
    if (settings.deviceKey.isEmpty) {
      settings._values['device_key'] = _generateKey();
      settings._values['device_name'] ??= _defaultDeviceName();
      await settings._persist();
    }
    return settings;
  }

  /// An in-memory instance for tests and previews.
  factory AppSettings.inMemory({Map<String, Object?> values = const {}}) =>
      AppSettings._(File('${Directory.systemTemp.path}/fundus-preview.json'), {
        'device_key': 'preview',
        'device_name': 'Vorschau',
        ...values,
      }, ephemeral: true);

  String get deviceKey => _values['device_key'] as String? ?? '';

  String get deviceName =>
      _values['device_name'] as String? ?? _defaultDeviceName();

  ThemeMode get themeMode => switch (_values['theme_mode']) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  FundusDensity get density => _values['density'] == 'compact'
      ? FundusDensity.compact
      : FundusDensity.comfortable;

  bool get navigationCollapsed => _values['navigation_collapsed'] == true;

  /// Up to ten vault paths, most recent first.
  List<String> get recentVaults {
    final value = _values['recent_vaults'];
    return value is List ? value.whereType<String>().toList() : const [];
  }

  Future<void> setDeviceName(String value) => _set('device_name', value.trim());

  Future<void> setThemeMode(ThemeMode mode) => _set('theme_mode', mode.name);

  Future<void> toggleTheme() => setThemeMode(
    themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
  );

  Future<void> setDensity(FundusDensity value) => _set('density', value.name);

  Future<void> toggleDensity() => setDensity(density.toggled);

  Future<void> setNavigationCollapsed(bool value) =>
      _set('navigation_collapsed', value);

  Future<void> rememberVault(String path) async {
    final vaults = [path, ...recentVaults.where((entry) => entry != path)];
    await _set('recent_vaults', vaults.take(10).toList());
  }

  Future<void> forgetVault(String path) async {
    await _set(
      'recent_vaults',
      recentVaults.where((entry) => entry != path).toList(),
    );
  }

  Future<void> _set(String key, Object? value) async {
    _values[key] = value;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    if (_ephemeral) return;
    try {
      await _file.parent.create(recursive: true);
      final partial = File('${_file.path}.part');
      await partial.writeAsString(jsonEncode(_values), flush: true);
      if (await _file.exists()) await _file.delete();
      await partial.rename(_file.path);
    } on FileSystemException {
      // Losing a preference is not worth interrupting the user for.
    }
  }

  static String _generateKey() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final noise = identityHashCode(Object()).toRadixString(16);
    return 'dev-$now-$noise';
  }

  static String _defaultDeviceName() {
    if (Platform.isAndroid) return 'Android-Gerät';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows-PC';
    if (Platform.isLinux) return 'Linux-Rechner';
    return 'Dieses Gerät';
  }
}
