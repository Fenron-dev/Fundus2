import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/peer_connection.dart';
import '../data/protection.dart';
import 'device_name.dart';

/// A library path the local Fundus server should expose.
///
/// Paths are installation-local and deliberately stay out of the vault. The
/// server may offer several vaults at once, while the active library remains
/// the one shown by the app itself.
final class ServerLibraryPreference {
  const ServerLibraryPreference({
    required this.path,
    required this.name,
    this.enabled = true,
  });

  final String path;
  final String name;
  final bool enabled;

  factory ServerLibraryPreference.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Ungültige Serverbibliothek.');
    }
    final path = value['path'];
    final name = value['name'];
    if (path is! String || path.trim().isEmpty) {
      throw const FormatException('Serverbibliothek ohne Pfad.');
    }
    return ServerLibraryPreference(
      path: path,
      name: name is String && name.trim().isNotEmpty ? name.trim() : path,
      enabled: value['enabled'] != false,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'enabled': enabled,
  };
}

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
  AppSettings._(
    this._file,
    this._values, {
    bool ephemeral = false,
    FlutterSecureStorage? secureStorage,
  }) : _ephemeral = ephemeral,
       _secureStorage = secureStorage;

  static const fileName = 'device.json';

  final File _file;

  /// Tests and previews keep their settings in memory; writing them would only
  /// leave files behind.
  final bool _ephemeral;
  final FlutterSecureStorage? _secureStorage;
  Map<String, Object?> _values;

  static const _sensitiveKeys = {'peers', 'tmdb_key', 'protection_pin'};

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
    final secureStorage = const FlutterSecureStorage();
    var hadPlainSensitiveValues = false;
    for (final key in _sensitiveKeys) {
      try {
        final encoded = await secureStorage.read(key: key);
        if (encoded != null) {
          values[key] = jsonDecode(encoded);
        } else if (values.containsKey(key)) {
          hadPlainSensitiveValues = true;
        }
      } on Object {
        // A platform without a registered backend keeps legacy settings
        // usable; the JSON file remains protected by app storage and chmod.
      }
    }
    final settings = AppSettings._(file, values, secureStorage: secureStorage);
    if (hadPlainSensitiveValues) await settings._persist();
    if (settings.deviceKey.isEmpty) {
      settings._values['device_key'] = _generateKey();
      settings._values['device_name'] ??= await platformDeviceName();
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

  /// What this device calls itself. Asked of the platform once, on the first
  /// start; a getter cannot wait for a channel, so this is the dull fallback
  /// for the moment before that answer is stored.
  String get deviceName {
    final stored = _values['device_name'];
    return stored is String && stored.trim().isNotEmpty
        ? stored
        : 'Dieses Gerät';
  }

  ThemeMode get themeMode => switch (_values['theme_mode']) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  FundusDensity get density => _values['density'] == 'compact'
      ? FundusDensity.compact
      : FundusDensity.comfortable;

  bool get navigationCollapsed => _values['navigation_collapsed'] == true;

  /// Whether the player shows its list of episodes and chapters beside the
  /// picture. Off by default: a film wants the screen, not a sidebar.
  bool get playerPanelVisible => _values['player_panel_visible'] == true;

  /// Whether Fundus looks for new files by itself.
  ///
  /// On by default, because a check costs one walk of the folder and having
  /// to press a button to learn that a series copied in an hour ago exists is
  /// the kind of chore a library should not have.
  bool get watchesLibrary => _values['watches_library'] != false;

  /// The TMDB key, if this device has one.
  ///
  /// Here rather than in the vault, for the same reason the pairing tokens
  /// are: a vault folder is shared by definition, and a key is a credential
  /// belonging to the person, not to the library. AniList and Open Library
  /// need none, so this stays empty for most people.
  String get tmdbKey => _values['tmdb_key'] as String? ?? '';

  /// Whether the reading position question has been answered for good.
  ///
  /// „Künftig immer die weiteste Stelle" — set from the sheet itself, because
  /// that is where somebody realises they never want to be asked again.
  bool get alwaysFurthestPosition => _values['always_furthest'] == true;

  /// Which language metadata is asked for.
  String get metadataLanguage =>
      _values['metadata_language'] as String? ?? 'de-DE';

  /// The Fundus installations this device has been paired with.
  ///
  /// Here rather than in the vault: each entry carries a bearer token, and a
  /// vault folder is shared by definition.
  List<PeerConnection> get peers {
    final value = _values['peers'];
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map)
          PeerConnection.fromJson(Map<String, Object?>.from(entry)),
    ];
  }

  Future<void> savePeer(PeerConnection peer) async {
    final others = peers.where((other) => other.serverId != peer.serverId);
    await _set('peers', [
      for (final entry in [...others, peer]) entry.toJson(),
    ]);
  }

  Future<void> forgetPeer(String serverId) async {
    await _set('peers', [
      for (final entry in peers)
        if (entry.serverId != serverId) entry.toJson(),
    ]);
  }

  /// The order the shelves stand in, as media type ids.
  ///
  /// Empty means the built-in order. A shelf missing from the list keeps its
  /// place at the end, so this never has to be complete.
  List<String> get mediaTypeOrder {
    final value = _values['media_type_order'];
    return value is List ? value.whereType<String>().toList() : const [];
  }

  Future<void> setMediaTypeOrder(List<String> value) =>
      _set('media_type_order', value);

  /// Up to ten vault paths, most recent first.
  List<String> get recentVaults {
    final value = _values['recent_vaults'];
    return value is List ? value.whereType<String>().toList() : const [];
  }

  /// Vaults explicitly selected for the local server. An empty list keeps the
  /// backwards-compatible behaviour: the currently open vault is shared.
  List<ServerLibraryPreference> get serverLibraries {
    final value = _values['server_libraries'];
    if (value is! List) return const [];
    final result = <ServerLibraryPreference>[];
    for (final entry in value) {
      try {
        result.add(ServerLibraryPreference.fromJson(entry));
      } on FormatException {
        // One damaged entry must not hide the other configured libraries.
      }
    }
    return result;
  }

  Future<void> setServerLibraries(List<ServerLibraryPreference> value) =>
      _set('server_libraries', [for (final entry in value) entry.toJson()]);

  /// Renames this device, unless the new name says nothing.
  ///
  /// An empty field is a field someone cleared on the way to typing, not a
  /// request to be called nothing.
  /// How much of the protected shelf is shown.
  ProtectionMode get protectionMode => switch (_values['protection_mode']) {
    'blur' => ProtectionMode.blur,
    'hide' => ProtectionMode.hide,
    _ => ProtectionMode.off,
  };

  /// The PIN as `salt:digest`, never as digits, and never in the vault: a
  /// library folder is shared by definition.
  String get protectionPin => _values['protection_pin'] as String? ?? '';

  Future<void> setProtectionMode(ProtectionMode value) =>
      _set('protection_mode', value.name);

  Future<void> setProtectionPin(String value) => _set('protection_pin', value);

  Future<void> setDeviceName(String value) async {
    final name = value.trim();
    if (name.isEmpty || name == deviceName) return;
    await _set('device_name', name);
  }

  /// The colour the interface is drawn in, or null for the one it ships with.
  ///
  /// One value, not a palette: the ramp is derived from it, so contrast is
  /// never somebody's problem to get right.
  Color? get accentColor {
    final value = _values['accent_color'];
    return value is int ? Color(value) : null;
  }

  Future<void> setAccentColor(Color? value) =>
      _set('accent_color', value?.toARGB32());

  /// How large the type is, as a factor. 1 is the designed size.
  double get textScale {
    final value = _values['text_scale'];
    if (value is! num) return 1;
    return value.toDouble().clamp(0.8, 1.6);
  }

  Future<void> setTextScale(double value) =>
      _set('text_scale', value.clamp(0.8, 1.6));

  Future<void> setThemeMode(ThemeMode mode) => _set('theme_mode', mode.name);

  Future<void> toggleTheme() => setThemeMode(
    themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
  );

  Future<void> setDensity(FundusDensity value) => _set('density', value.name);

  Future<void> toggleDensity() => setDensity(density.toggled);

  Future<void> setNavigationCollapsed(bool value) =>
      _set('navigation_collapsed', value);

  Future<void> setPlayerPanelVisible(bool value) =>
      _set('player_panel_visible', value);

  Future<void> setWatchesLibrary(bool value) => _set('watches_library', value);

  Future<void> setAlwaysFurthestPosition(bool value) =>
      _set('always_furthest', value);

  Future<void> setTmdbKey(String value) => _set('tmdb_key', value.trim());

  Future<void> setMetadataLanguage(String value) =>
      _set('metadata_language', value);

  /// The security bookmarks that let macOS reach a folder again after a
  /// restart, by folder. They belong to this machine and this installation,
  /// never to the vault.
  Map<String, String> get vaultBookmarks {
    final value = _values['vault_bookmarks'];
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  Future<void> setVaultBookmarks(Map<String, String> value) =>
      _set('vault_bookmarks', value);

  Future<void> rememberVault(String path) async {
    final vaults = [path, ...recentVaults.where((entry) => entry != path)];
    await _set('recent_vaults', vaults.take(10).toList());
  }

  Future<void> forgetVault(String path) async {
    await _set(
      'recent_vaults',
      recentVaults.where((entry) => entry != path).toList(),
    );
    final bookmarks = vaultBookmarks;
    if (bookmarks.containsKey(path)) {
      await setVaultBookmarks({...bookmarks}..remove(path));
    }
  }

  Future<void> _set(String key, Object? value) async {
    _values[key] = value;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    if (_ephemeral) return;
    try {
      var storedSecurely = _secureStorage != null;
      if (storedSecurely) {
        try {
          for (final key in _sensitiveKeys) {
            await _secureStorage.write(
              key: key,
              value: _values.containsKey(key) ? jsonEncode(_values[key]) : null,
            );
          }
        } on Object {
          // Keep the value usable if a platform has no working keychain. The
          // fallback is still protected by app storage and Unix file mode.
          storedSecurely = false;
        }
      }
      await _file.parent.create(recursive: true);
      final partial = File('${_file.path}.part');
      final persisted = Map<String, Object?>.from(_values);
      if (storedSecurely) {
        for (final key in _sensitiveKeys) {
          persisted.remove(key);
        }
      }
      await partial.writeAsString(jsonEncode(persisted), flush: true);
      if (await _file.exists()) await _file.delete();
      await partial.rename(_file.path);
      if (!Platform.isWindows) {
        // device.json contains bearer tokens, the protection verifier and
        // optional provider credentials. Keep it private on Unix desktops;
        // Android's application sandbox remains the primary boundary there.
        try {
          await Process.run('chmod', ['600', _file.path]);
        } on ProcessException {
          // Some sandboxed platforms do not expose chmod; the file is still
          // inside the platform's application-support directory.
        }
      }
    } on FileSystemException {
      // Losing a preference is not worth interrupting the user for.
    }
  }

  static String _generateKey() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final noise = identityHashCode(Object()).toRadixString(16);
    return 'dev-$now-$noise';
  }
}
