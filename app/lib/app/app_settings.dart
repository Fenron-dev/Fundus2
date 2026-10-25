import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_core/fundus_core.dart'
    show OfflinePolicy, OfflineRule, OfflineCheckpointReceipt;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/peer_connection.dart';
import '../data/protection.dart';
import 'device_name.dart';
import '../media/speech_profile.dart';

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
/// Shared reader/player settings live in the vault's `_fundus/devices/`
/// directory. Installation-specific engine choices (for example a local TTS
/// model path and per-work voice preferences) live here, because they describe
/// this device's engine installation rather than the shared reading position.
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
  Future<void> _persistQueue = Future<void>.value();
  bool _secureStorageAvailable = true;
  final Map<String, String> _storedSensitiveValues = {};
  bool get secureStorageAvailable => _secureStorageAvailable;
  Map<String, Object?> _values;

  static const _sensitiveKeys = {
    'peers',
    'tmdb_key',
    'hardcover_token',
    'mal_client_id',
    'protection_pin',
  };

  static Future<AppSettings> load({
    File? settingsFile,
    FlutterSecureStorage? storage,
  }) async {
    final file =
        settingsFile ??
        File(p.join((await getApplicationSupportDirectory()).path, fileName));
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
    final secureStorage = storage ?? const FlutterSecureStorage();
    var hadPlainSensitiveValues = false;
    var secureReadsSucceeded = true;
    final secured = <String, String>{};
    for (final key in _sensitiveKeys) {
      try {
        final encoded = await secureStorage.read(key: key);
        if (encoded != null) {
          values[key] = jsonDecode(encoded);
          secured[key] = encoded;
        } else if (values.containsKey(key)) {
          hadPlainSensitiveValues = true;
        }
      } on Object {
        // Do not replace unreadable credentials with empty values, nor fall
        // back to plaintext. A later successful secure write can retry.
        secureReadsSucceeded = false;
      }
    }
    final settings = AppSettings._(file, values, secureStorage: secureStorage);
    settings._secureStorageAvailable = secureReadsSucceeded;
    settings._storedSensitiveValues.addAll(secured);
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

  List<SpeechProfile> get speechProfiles {
    final raw = _values['speech_profiles'];
    if (raw is! List) return const [];
    final result = <SpeechProfile>[];
    for (final value in raw.whereType<Map>()) {
      try {
        result.add(SpeechProfile.fromJson(value));
      } on Object {
        /* Preserve other valid profiles. */
      }
    }
    return result;
  }

  Future<void> setSpeechProfiles(List<SpeechProfile> values) =>
      _set('speech_profiles', [for (final value in values) value.toJson()]);

  String? speechProfileId(String workId) {
    final values = _values['speech_profile_by_work'];
    final value = values is Map ? values[workId] : null;
    return value is String ? value : null;
  }

  SpeechProfile? speechProfileFor(String workId, String language) {
    final profiles = speechProfiles;
    final selected = speechProfileId(workId);
    for (final profile in profiles) {
      if (profile.id == selected) return profile;
    }
    for (final profile in profiles) {
      if (profile.language == language) return profile;
    }
    return null;
  }

  Future<void> setSpeechProfileId(String workId, String? id) {
    final raw = _values['speech_profile_by_work'];
    final values = raw is Map
        ? Map<String, Object?>.from(raw)
        : <String, Object?>{};
    if (id == null) {
      values.remove(workId);
    } else {
      values[workId] = id;
    }
    return _set('speech_profile_by_work', values);
  }

  List<SpeechDictionary> get speechDictionaries {
    final raw = _values['speech_dictionaries'];
    if (raw is! List) return const [];
    final result = <SpeechDictionary>[];
    for (final value in raw.whereType<Map>()) {
      try {
        result.add(SpeechDictionary.fromJson(value));
      } on Object {
        /* Keep valid dictionaries. */
      }
    }
    return result;
  }

  Future<void> setSpeechDictionaries(List<SpeechDictionary> values) =>
      _set('speech_dictionaries', [for (final value in values) value.toJson()]);

  Map<String, String> effectiveSpeechPronunciations(
    String workId,
    SpeechProfile? profile,
  ) => {
    for (final dictionary in speechDictionaries)
      if (profile != null &&
          profile.dictionaryIds.contains(dictionary.id) &&
          (dictionary.language == null ||
              dictionary.language == profile.language))
        ...dictionary.entries,
    ...speechPronunciations(workId),
  };

  /// Local Phonon checkpoint folder selected on this installation. Model
  /// files are kept out of the shared vault and device sync.
  String? get phononModelDirectory {
    final value = _values['phonon_model_directory'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  Future<void> setPhononModelDirectory(String? value) => _set(
    'phonon_model_directory',
    value == null || value.trim().isEmpty ? null : value.trim(),
  );

  /// CPU model offered to paired devices; a Mac may use a different Core-ML
  /// bundle for its own playback. This path is installation-local as well.
  String? get phononServerModelDirectory {
    final value = _values['phonon_server_model_directory'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  Future<void> setPhononServerModelDirectory(String? value) => _set(
    'phonon_server_model_directory',
    value?.trim().isEmpty == true ? null : value?.trim(),
  );

  String? speechLanguageOverride(String workId) {
    final raw = _values['speech_language_overrides'];
    if (raw is! Map) return null;
    final value = raw[workId];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  Future<void> setSpeechLanguageOverride(String workId, String? language) {
    final raw = _values['speech_language_overrides'];
    final overrides = raw is Map
        ? Map<String, Object?>.from(raw.cast<Object?, Object?>())
        : <String, Object?>{};
    if (language == null || language.trim().isEmpty) {
      overrides.remove(workId);
    } else {
      overrides[workId] = language.trim();
    }
    return _set('speech_language_overrides', overrides);
  }

  String? speechVoice(String workId, String languageCode) {
    final raw = _values['speech_voices'];
    if (raw is! Map) return null;
    final value = raw['$workId:$languageCode'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  Future<void> setSpeechVoice(
    String workId,
    String languageCode,
    String? voice,
  ) {
    final raw = _values['speech_voices'];
    final voices = raw is Map
        ? Map<String, Object?>.from(raw.cast<Object?, Object?>())
        : <String, Object?>{};
    final key = '$workId:$languageCode';
    if (voice == null || voice.trim().isEmpty) {
      voices.remove(key);
    } else {
      voices[key] = voice.trim();
    }
    return _set('speech_voices', voices);
  }

  double speechRate(String workId) {
    final raw = _values['speech_rates'];
    if (raw is! Map) return 1;
    final value = raw[workId];
    if (value is! num || !value.toDouble().isFinite) return 1;
    return value.toDouble().clamp(0.5, 2.5);
  }

  Future<void> setSpeechRate(String workId, double rate) {
    if (!rate.isFinite || rate < 0.5 || rate > 2.5) {
      throw ArgumentError.value(
        rate,
        'rate',
        'Expected a value from 0.5 to 2.5',
      );
    }
    final raw = _values['speech_rates'];
    final rates = raw is Map
        ? Map<String, Object?>.from(raw.cast<Object?, Object?>())
        : <String, Object?>{};
    rates[workId] = rate;
    return _set('speech_rates', rates);
  }

  Map<String, String> speechPronunciations(String workId) {
    final raw = _values['speech_pronunciations'];
    if (raw is! Map || raw[workId] is! Map) return const {};
    return Map<String, String>.fromEntries(
      (raw[workId]! as Map).entries
          .where(
            (entry) =>
                entry.key is String &&
                entry.value is String &&
                (entry.key as String).trim().isNotEmpty &&
                (entry.value as String).trim().isNotEmpty,
          )
          .map(
            (entry) => MapEntry(
              (entry.key as String).trim(),
              (entry.value as String).trim(),
            ),
          ),
    );
  }

  Future<void> setSpeechPronunciations(
    String workId,
    Map<String, String> pronunciations,
  ) {
    final raw = _values['speech_pronunciations'];
    final values = raw is Map
        ? Map<String, Object?>.from(raw.cast<Object?, Object?>())
        : <String, Object?>{};
    final clean = <String, String>{};
    for (final entry in pronunciations.entries) {
      final source = entry.key.trim();
      final spoken = entry.value.trim();
      if (source.isNotEmpty && spoken.isNotEmpty) clean[source] = spoken;
    }
    if (clean.isEmpty) {
      values.remove(workId);
    } else {
      values[workId] = clean;
    }
    return _set('speech_pronunciations', values);
  }

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
  /// Kept as a compatibility getter for older settings files. New code uses
  /// [libraryScanInterval], which can disable automatic scans entirely.
  bool get watchesLibrary => libraryScanIntervalMinutes > 0;

  /// Automatic library scan interval in minutes. Zero means manual scans only.
  ///
  /// Progress synchronisation is deliberately not controlled by this value:
  /// progress is a small database exchange and never walks the media folder.
  int get libraryScanIntervalMinutes {
    final value = _values['library_scan_interval_minutes'];
    if (value is num) return value.toInt().clamp(0, 1440);
    // New installations default to manual checks. Legacy settings that had
    // the old boolean enabled can opt into a cycle explicitly in Settings;
    // this avoids waking test and preview shells unexpectedly.
    return 0;
  }

  /// Whether the small progress/annotation exchange runs when the app starts.
  /// This never triggers a filesystem scan.
  bool get syncProgressOnStartup =>
      _values['sync_progress_on_startup'] != false;

  /// Whether opening a vault performs one file scan immediately.
  bool get scanOnStartup => _values['scan_on_startup'] == true;

  /// Physical offline budgets/rules belong to this installation, not a vault
  /// copied to another phone or an archive disk. Invalid data is not reset.
  OfflinePolicy get offlinePolicy => _values['offline_policy'] == null
      ? const OfflinePolicy()
      : OfflinePolicy.fromJson(_values['offline_policy']);

  List<OfflineCheckpointReceipt> get offlineCheckpointReceipts {
    final raw = _values['offline_checkpoint_receipts'];
    if (raw == null) return const [];
    if (raw is! Map ||
        raw['format_version'] != 1 ||
        raw['receipts'] is! List ||
        (raw['receipts'] as List).length > 5000) {
      throw const FormatException('Nicht unterstützte Offline-Bestätigungen.');
    }
    return (raw['receipts'] as List)
        .map(OfflineCheckpointReceipt.fromJson)
        .toList(growable: false);
  }

  Future<void> saveOfflineCheckpointReceipts(
    Iterable<OfflineCheckpointReceipt> additions,
  ) {
    final byKey = <String, OfflineCheckpointReceipt>{};
    for (final receipt in [...offlineCheckpointReceipts, ...additions]) {
      final validated = OfflineCheckpointReceipt.fromJson(receipt.toJson());
      byKey['${validated.vaultId}:${validated.workId}:${validated.deviceId}'] =
          validated;
    }
    final recent = byKey.values.toList()
      ..sort((a, b) => b.confirmedAt.compareTo(a.confirmedAt));
    return _set('offline_checkpoint_receipts', {
      'format_version': 1,
      'receipts': recent.take(5000).map((receipt) => receipt.toJson()).toList(),
    });
  }

  Future<void> setOfflinePolicy(OfflinePolicy policy) {
    offlinePolicy;
    policy.validate();
    return _set('offline_policy', policy.toJson());
  }

  List<OfflineRule> offlineRules(String libraryId) {
    final values = _values['offline_rules'];
    if (values == null) return const [];
    if (values is! Map ||
        values['format_version'] != 1 ||
        values['libraries'] is! Map) {
      throw const FormatException('Nicht unterstützte Offline-Auswahl.');
    }
    final rules = (values['libraries'] as Map)[libraryId];
    if (rules == null) return const [];
    if (rules is! List || rules.length > 1000) {
      throw const FormatException('Offline-Auswahl ist zu groß oder ungültig.');
    }
    return rules.map(OfflineRule.fromJson).toList(growable: false);
  }

  Future<void> setOfflineRules(String libraryId, List<OfflineRule> rules) =>
      _set('offline_rules', _offlineRulesValue(libraryId, rules));

  Future<void> setOfflineConfiguration(
    String libraryId,
    OfflinePolicy policy,
    List<OfflineRule> rules,
  ) async {
    offlinePolicy;
    policy.validate();
    final ruleValue = _offlineRulesValue(libraryId, rules);
    _values['offline_policy'] = policy.toJson();
    _values['offline_rules'] = ruleValue;
    notifyListeners();
    await _persist();
  }

  Map<String, Object?> _offlineRulesValue(
    String libraryId,
    List<OfflineRule> rules,
  ) {
    offlineRules(libraryId); // Preserve unknown versions instead of clobbering.
    if (rules.length > 1000) {
      throw const FormatException('Zu viele Offline-Regeln.');
    }
    final normalized = {
      for (final rule in rules) rule.key: OfflineRule.fromJson(rule.toJson()),
    };
    final old = _values['offline_rules'] as Map?;
    return {
      'format_version': 1,
      'libraries': {
        if (old?['libraries'] case final Map libraries) ...libraries,
        libraryId: normalized.values.map((rule) => rule.toJson()).toList(),
      },
    };
  }

  /// The TMDB key, if this device has one.
  ///
  /// Here rather than in the vault, for the same reason the pairing tokens
  /// are: a vault folder is shared by definition, and a key is a credential
  /// belonging to the person, not to the library. AniList and Open Library
  /// need none, so this stays empty for most people.
  String get tmdbKey => _values['tmdb_key'] as String? ?? '';

  /// Personal Hardcover API token. It is device-local and never part of a
  /// shared vault, just like the TMDB key.
  String get hardcoverToken => _values['hardcover_token'] as String? ?? '';

  /// Client-Kennung für die offizielle MyAnimeList-Schnittstelle.
  ///
  /// Kostenlos unter `myanimelist.net/apiconfig` anzulegen und ohne OAuth
  /// gültig, solange nur öffentliche Angaben gelesen werden. Liegt wie die
  /// übrigen Zugangsdaten im geschützten Speicher des Geräts, nie im Vault.
  String get malClientId => _values['mal_client_id'] as String? ?? '';

  /// Whether the reading position question has been answered for good.
  ///
  /// „Künftig immer die weiteste Stelle" — set from the sheet itself, because
  /// that is where somebody realises they never want to be asked again.
  bool get alwaysFurthestPosition => _values['always_furthest'] == true;

  /// Which language metadata is asked for.
  String get metadataLanguage =>
      _values['metadata_language'] as String? ?? 'de-DE';
  bool get automaticMetadataReview =>
      _values['automatic_metadata_review'] != false;
  Future<void> setAutomaticMetadataReview(bool value) =>
      _set('automatic_metadata_review', value);

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

  /// Media-root names that get their own first-class navigation entry.
  ///
  /// The classification itself stays in the vault; this is only a device UI
  /// preference, so a phone and a desktop may organise their sidebar
  /// differently without changing the library.
  Set<String> get navigationMediaRoots {
    final value = _values['navigation_media_roots'];
    return value is List
        ? value.whereType<String>().where((root) => root.isNotEmpty).toSet()
        : const {};
  }

  /// Welche Bibliotheken in der Seitenleiste aufgeklappt sind.
  ///
  /// Geräteeigene Darstellungssache, wie die Medienordner darüber. Vorher lag
  /// das nur im Widget: die mobile Schublade baut die Leiste bei jedem Öffnen
  /// neu, und damit klappte jede Bibliothek jedes Mal wieder zu.
  Set<String> get expandedSources {
    final value = _values['expanded_sources'];
    return value is List
        ? value.whereType<String>().where((id) => id.isNotEmpty).toSet()
        : const {};
  }

  Future<void> setSourceExpanded(String sourceId, bool expanded) async {
    final sources = {...expandedSources};
    if (expanded) {
      sources.add(sourceId);
    } else {
      sources.remove(sourceId);
    }
    await _set('expanded_sources', sources.toList()..sort());
  }

  Future<void> setMediaRootInNavigation(String root, bool visible) async {
    final roots = {...navigationMediaRoots};
    if (visible) {
      roots.add(root);
    } else {
      roots.remove(root);
    }
    await _set('navigation_media_roots', roots.toList()..sort());
  }

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

  /// Sources hidden from this installation's combined catalogue. The source
  /// rows and their catalogues remain in the shell vault; this is only a local
  /// visibility preference, like Plex's library visibility setting. The local
  /// shell source can be hidden too, which allows a temporary presentation
  /// profile without deleting offline data.
  List<String> get hiddenSourceIds {
    final value = _values['hidden_source_ids'];
    return value is List
        ? value.whereType<String>().where((id) => id.isNotEmpty).toList()
        : const [];
  }

  Future<void> setSourceVisible(String sourceId, bool visible) async {
    final hidden = {...hiddenSourceIds};
    if (visible) {
      hidden.remove(sourceId);
    } else {
      hidden.add(sourceId);
    }
    await _set('hidden_source_ids', hidden.toList()..sort());
  }

  /// Works hidden from the dashboard's recent/continue rails on this device.
  /// Progress and catalogue metadata remain untouched; this is only a local
  /// presentation preference and therefore must not be written to the vault.
  List<String> get dashboardHiddenWorkIds {
    final value = _values['dashboard_hidden_work_ids'];
    return value is List
        ? value.whereType<String>().where((id) => id.isNotEmpty).toList()
        : const [];
  }

  Future<void> setDashboardWorkVisible(String workId, bool visible) async {
    final hidden = {...dashboardHiddenWorkIds};
    if (visible) {
      hidden.remove(workId);
    } else {
      hidden.add(workId);
    }
    await _set('dashboard_hidden_work_ids', hidden.toList()..sort());
  }

  /// Renames this device, unless the new name says nothing.
  ///
  /// An empty field is a field someone cleared on the way to typing, not a
  /// request to be called nothing.
  /// How much of the protected shelf is shown.
  ProtectionMode get protectionMode => switch (_values['protection_mode']) {
    // Preview builds offered a cover-only blur. A closed dashboard lock must
    // never leave protected titles, descriptions or navigation counts in
    // view, so old installations migrate to the unequivocal hidden state.
    'blur' => ProtectionMode.hide,
    'hide' => ProtectionMode.hide,
    _ => ProtectionMode.off,
  };

  /// The PIN as `salt:digest`, never as digits, and never in the vault: a
  /// library folder is shared by definition.
  String get protectionPin => _values['protection_pin'] as String? ?? '';

  Future<void> setProtectionMode(ProtectionMode value) =>
      _set('protection_mode', value.name);

  Future<void> setProtectionPin(String value) => _set('protection_pin', value);

  /// Wie viele Fehlversuche seit dem letzten gelungenen Entsperren.
  ///
  /// Gehört bewusst in die Einstellungen und nicht bloß in den Speicher: eine
  /// Versuchsbegrenzung, die ein Neustart der App aufhebt, ist bei einer
  /// vierstelligen PIN keine Begrenzung. Der Wert ist kein Geheimnis, er
  /// braucht deshalb auch nicht in den Schlüsselbund.
  int get protectionFailedAttempts =>
      switch (_values['protection_failed_attempts']) {
        final int value when value >= 0 => value,
        _ => 0,
      };

  /// Bis wann nicht weiter probiert werden darf, oder `null`.
  DateTime? get protectionLockedUntil =>
      switch (_values['protection_locked_until']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      };

  Future<void> setProtectionLockout({
    required int failedAttempts,
    DateTime? lockedUntil,
  }) async {
    _values['protection_failed_attempts'] = failedAttempts;
    _values['protection_locked_until'] = lockedUntil?.toUtc().toIso8601String();
    notifyListeners();
    await _persist();
  }

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

  Future<void> setWatchesLibrary(bool value) async {
    await _set('watches_library', value);
    if (!value) {
      await _set('library_scan_interval_minutes', 0);
    } else if (_values['library_scan_interval_minutes'] is! num ||
        libraryScanIntervalMinutes == 0) {
      await _set('library_scan_interval_minutes', 60);
    }
  }

  Future<void> setLibraryScanIntervalMinutes(int minutes) async {
    final safe = minutes.clamp(0, 1440);
    await _set('library_scan_interval_minutes', safe);
    await _set('watches_library', safe > 0);
  }

  Future<void> setSyncProgressOnStartup(bool value) =>
      _set('sync_progress_on_startup', value);

  Future<void> setScanOnStartup(bool value) => _set('scan_on_startup', value);

  Future<void> setAlwaysFurthestPosition(bool value) =>
      _set('always_furthest', value);

  Future<void> setTmdbKey(String value) => _set('tmdb_key', value.trim());

  Future<void> setHardcoverToken(String value) =>
      _set('hardcover_token', value.trim());

  Future<void> setMalClientId(String value) =>
      _set('mal_client_id', value.trim());

  /// Das Zugangsdatum zu einem Dienst, über seinen stabilen Schlüssel.
  ///
  /// Ein Zugriffspunkt statt einer Fallunterscheidung an jeder Aufrufstelle —
  /// der Massenabgleich hatte dadurch jedem Dienst den TMDB-Schlüssel
  /// gereicht, auch denen, für die er nichts bedeutet.
  String credentialFor(String? key) => switch (key) {
    'tmdb' => tmdbKey,
    'hardcover' => hardcoverToken,
    'mal' => malClientId,
    _ => '',
  };

  Future<void> setCredential(String? key, String value) async => switch (key) {
    'tmdb' => setTmdbKey(value),
    'hardcover' => setHardcoverToken(value),
    'mal' => setMalClientId(value),
    _ => null,
  };

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

  Future<void> _persist() {
    if (_ephemeral) return Future<void>.value();
    final snapshot = Map<String, Object?>.from(_values);
    final operation = _persistQueue.then((_) => _persistValues(snapshot));
    _persistQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _persistValues(Map<String, Object?> snapshot) async {
    if (_ephemeral) return;
    try {
      var storedSecurely = _secureStorage != null;
      if (storedSecurely) {
        try {
          for (final key in _sensitiveKeys) {
            if (!snapshot.containsKey(key)) continue;
            final encoded = jsonEncode(snapshot[key]);
            if (_storedSensitiveValues[key] == encoded) continue;
            await _secureStorage.write(key: key, value: encoded);
            if (await _secureStorage.read(key: key) != encoded) {
              throw StateError('Sichere Speicherung wurde nicht bestätigt.');
            }
            _storedSensitiveValues[key] = encoded;
          }
        } on Object {
          // Keep credentials in memory for this session; do not fall back to plaintext.
          storedSecurely = false;
        }
      }
      if (_secureStorageAvailable != storedSecurely) {
        _secureStorageAvailable = storedSecurely;
        notifyListeners();
      }
      // Keep legacy files until successful migration; never erase pairings
      // merely because the keychain is temporarily unavailable.
      if (!storedSecurely) return;
      await _file.parent.create(recursive: true);
      final partial = File('${_file.path}.part');
      final persisted = Map<String, Object?>.from(snapshot);
      if (storedSecurely) {
        for (final key in _sensitiveKeys) {
          persisted.remove(key);
        }
      }
      await partial.writeAsString(jsonEncode(persisted), flush: true);
      await partial.rename(_file.path);
      if (!Platform.isWindows) {
        // Preferences still reveal paths and device names. Credentials live
        // exclusively in the platform store after successful migration.
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
