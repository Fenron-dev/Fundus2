/// What one device remembers about how it shows this library.
///
/// This deliberately departs from "device state is device-bound": reader and
/// player settings are written into the vault's own `_fundus/devices/`
/// directory rather than into app storage. Reinstalling the app — the normal
/// way an Android build is updated — wipes app storage, and losing every
/// reader setting on every update is a real, repeatedly observed failure.
///
/// What stays strictly local is *identity*: the device key, pairing tokens,
/// certificates and private keys never travel in the vault. A copied vault
/// therefore carries settings that a new device may adopt on purpose, but it
/// can never impersonate the device those settings came from.
final class DeviceProfile {
  const DeviceProfile({
    required this.key,
    required this.displayName,
    this.platform = '',
    this.updatedAt,
    this.settings = const {},
  });

  static const formatVersion = 1;

  /// Stable per-device key. It is generated on the device and stored locally;
  /// the copy here only labels the settings so a reinstalled app can offer to
  /// adopt them.
  final String key;

  final String displayName;

  /// `android`, `macos`, `windows`, `linux` — free text, shown to the user
  /// when several profiles are offered for adoption.
  final String platform;

  final DateTime? updatedAt;

  /// Reader and player settings, grouped by the reader kind that owns them
  /// (`manga`, `epub`, `pdf`, `audio`, `video`, `shell`).
  final Map<String, Object?> settings;

  Map<String, Object?> settingsFor(String kind) {
    final value = settings[kind];
    return value is Map
        ? Map<String, Object?>.from(value.cast<Object?, Object?>())
        : const {};
  }

  DeviceProfile withSettings(String kind, Map<String, Object?> values) {
    final merged = Map<String, Object?>.from(settings);
    merged[kind] = values;
    return DeviceProfile(
      key: key,
      displayName: displayName,
      platform: platform,
      updatedAt: DateTime.now(),
      settings: merged,
    );
  }

  DeviceProfile copyWith({String? displayName, String? platform}) =>
      DeviceProfile(
        key: key,
        displayName: displayName ?? this.displayName,
        platform: platform ?? this.platform,
        updatedAt: DateTime.now(),
        settings: settings,
      );

  Map<String, Object?> toJson() => {
    'format_version': formatVersion,
    'key': key,
    'display_name': displayName,
    'platform': platform,
    'updated_at': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'settings': settings,
  };

  static DeviceProfile? fromJson(Object? value) {
    if (value is! Map) return null;
    final key = value['key'];
    if (key is! String || key.isEmpty) return null;
    final updatedAt = value['updated_at'];
    final settings = value['settings'];
    return DeviceProfile(
      key: key,
      displayName: value['display_name'] is String
          ? value['display_name'] as String
          : key,
      platform: value['platform'] is String ? value['platform'] as String : '',
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      settings: settings is Map
          ? Map<String, Object?>.from(settings.cast<Object?, Object?>())
          : const {},
    );
  }
}
