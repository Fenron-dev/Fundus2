import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final class FundusPairedDevice {
  const FundusPairedDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.pairedAt,
    this.lastSeenAt,
    this.allowAdultExplicit = false,
    this.allowedLibraryIds,
    this.allowRemoteControl = false,
  });

  final String id;
  final String name;
  final String tokenHash;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;
  final bool allowAdultExplicit;

  /// Null means every currently shared library. A non-null set is an explicit
  /// allow-list for this device; an empty set therefore sees no catalogue.
  final Set<String>? allowedLibraryIds;

  /// Whether the device may start and steer playback on this machine. Off
  /// unless granted: a phone that can read a library has not therefore been
  /// asked to play things on somebody's speakers.
  final bool allowRemoteControl;

  FundusPairedDevice copyWith({
    String? name,
    DateTime? lastSeenAt,
    bool? allowAdultExplicit,
    Set<String>? Function()? allowedLibraryIds,
    bool? allowRemoteControl,
  }) => FundusPairedDevice(
    id: id,
    name: name ?? this.name,
    tokenHash: tokenHash,
    pairedAt: pairedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    allowAdultExplicit: allowAdultExplicit ?? this.allowAdultExplicit,
    allowedLibraryIds: allowedLibraryIds == null
        ? this.allowedLibraryIds
        : allowedLibraryIds(),
    allowRemoteControl: allowRemoteControl ?? this.allowRemoteControl,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'token_hash': tokenHash,
    'paired_at': pairedAt.toUtc().toIso8601String(),
    if (lastSeenAt != null)
      'last_seen_at': lastSeenAt!.toUtc().toIso8601String(),
    'allow_adult_explicit': allowAdultExplicit,
    if (allowedLibraryIds != null)
      'allowed_library_ids': allowedLibraryIds!.toList()..sort(),
    'allow_remote_control': allowRemoteControl,
  };

  static FundusPairedDevice? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final hash = value['token_hash'];
    final pairedAt = DateTime.tryParse('${value['paired_at'] ?? ''}');
    final lastSeenAt = DateTime.tryParse('${value['last_seen_at'] ?? ''}');
    if (id is! String ||
        name is! String ||
        hash is! String ||
        pairedAt == null) {
      return null;
    }
    return FundusPairedDevice(
      id: id,
      name: name,
      tokenHash: hash,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
      allowAdultExplicit: value['allow_adult_explicit'] == true,
      allowedLibraryIds: value['allowed_library_ids'] is List
          ? (value['allowed_library_ids'] as List)
                .whereType<String>()
                .where((id) => id.trim().isNotEmpty)
                .toSet()
          : null,
      allowRemoteControl: value['allow_remote_control'] == true,
    );
  }
}

final class FundusPairingSession {
  const FundusPairingSession({
    required this.nonce,
    required this.pin,
    required this.expiresAt,
  });

  final String nonce;
  final String pin;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

final class FundusPairingResult {
  const FundusPairingResult({required this.device, required this.token});

  final FundusPairedDevice device;
  final String token;
}

enum FundusPairingFailure { unavailable, invalid, expired, locked }

final class FundusPairingException implements Exception {
  const FundusPairingException(this.failure);

  final FundusPairingFailure failure;
}

typedef PairedDevicesChanged =
    Future<void> Function(List<FundusPairedDevice> devices);

/// Owns short-lived pairing sessions and long-lived, revocable device grants.
/// Only SHA-256 token digests are retained by the server.
final class FundusPairingAuthority {
  FundusPairingAuthority({
    Iterable<FundusPairedDevice> devices = const [],
    this.onChanged,
    this.onPaired,
    Random? random,
  }) : _random = random ?? Random.secure(),
       _devices = {for (final device in devices) device.id: device};

  final Random _random;
  final PairedDevicesChanged? onChanged;

  /// Told about every device that has just been paired, so whoever sits at
  /// this machine hears about it — a pairing nobody noticed is the one that
  /// should not have happened.
  final void Function(FundusPairedDevice device)? onPaired;
  final Map<String, FundusPairedDevice> _devices;
  FundusPairingSession? _session;
  int _failedAttempts = 0;

  List<FundusPairedDevice> get devices => List.unmodifiable(
    _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
  );

  FundusPairingSession? get activeSession {
    final session = _session;
    if (session == null || session.isExpired) {
      _session = null;
      return null;
    }
    return session;
  }

  FundusPairingSession begin({Duration lifetime = const Duration(minutes: 5)}) {
    final session = FundusPairingSession(
      nonce: _randomValue(18),
      pin: List.generate(6, (_) => _random.nextInt(10)).join(),
      expiresAt: DateTime.now().add(lifetime),
    );
    _failedAttempts = 0;
    _session = session;
    return session;
  }

  void cancel() {
    _session = null;
    _failedAttempts = 0;
  }

  Future<FundusPairingResult> claim({
    required String nonce,
    required String pin,
    required String deviceId,
    required String deviceName,
  }) async {
    final session = _session;
    if (session == null) {
      throw const FundusPairingException(FundusPairingFailure.unavailable);
    }
    if (session.isExpired) {
      cancel();
      throw const FundusPairingException(FundusPairingFailure.expired);
    }
    if (_failedAttempts >= 5) {
      cancel();
      throw const FundusPairingException(FundusPairingFailure.locked);
    }
    // The nonce identifies the pending invitation. Unrelated LAN requests
    // must not consume its PIN attempts and cancel another person's pairing.
    if (!_constantTimeEquals(nonce, session.nonce)) {
      throw const FundusPairingException(FundusPairingFailure.invalid);
    }
    if (!_constantTimeEquals(pin, session.pin)) {
      _failedAttempts++;
      if (_failedAttempts >= 5) _session = null;
      throw FundusPairingException(
        _failedAttempts >= 5
            ? FundusPairingFailure.locked
            : FundusPairingFailure.invalid,
      );
    }
    final normalizedId = deviceId.trim();
    final normalizedName = deviceName.trim();
    if (normalizedId.isEmpty ||
        normalizedId.length > 128 ||
        normalizedName.isEmpty ||
        normalizedName.length > 80) {
      throw const FundusPairingException(FundusPairingFailure.invalid);
    }
    final token = _randomValue(32);
    final now = DateTime.now().toUtc();
    // Ein Gerät, das sich erneut koppelt, ist dasselbe Gerät. Seine
    // Bibliotheks-Allowlist ist eine Einschränkung, die jemand gesetzt hat —
    // sie hier wegzulassen hieße `null`, und `libraryAllowed` liest `null`
    // als „jede Bibliothek". Eine Beschränkung darf sich nicht dadurch
    // auflösen, dass man den Kopplungsvorgang wiederholt.
    //
    // Die HHH-Freigabe wird bewusst *nicht* übernommen: dass sie auf `false`
    // zurückfällt, ist die sichere Richtung.
    final previous = _devices[normalizedId];
    final device = FundusPairedDevice(
      id: normalizedId,
      name: normalizedName,
      tokenHash: tokenDigest(token),
      pairedAt: now,
      lastSeenAt: now,
      allowedLibraryIds: previous?.allowedLibraryIds,
    );
    _devices[device.id] = device;
    cancel();
    await _notifyChanged();
    onPaired?.call(device);
    return FundusPairingResult(device: device, token: token);
  }

  bool authorize(String? bearerToken) {
    return authorizeDevice(bearerToken) != null;
  }

  /// Returns the paired device for a valid token and records recent activity.
  String? authorizeDevice(String? bearerToken) {
    if (bearerToken == null || bearerToken.isEmpty) return null;
    final digest = tokenDigest(bearerToken);
    for (final device in _devices.values) {
      if (!_constantTimeEquals(digest, device.tokenHash)) continue;
      _markSeen(device);
      return device.id;
    }
    return null;
  }

  void _markSeen(FundusPairedDevice device) {
    final now = DateTime.now().toUtc();
    final previous = device.lastSeenAt;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 10)) {
      return;
    }
    _devices[device.id] = device.copyWith(lastSeenAt: now);
    final callback = onChanged;
    if (callback != null) unawaited(callback(devices));
  }

  Future<void> revoke(String deviceId) async {
    if (_devices.remove(deviceId) != null) await _notifyChanged();
  }

  /// Unpairs every device that has not been heard from for [unused].
  ///
  /// A phone that was sold or lost keeps a valid token forever otherwise.
  /// Returns the devices taken off.
  Future<List<FundusPairedDevice>> revokeInactive(
    Duration unused, {
    DateTime? now,
  }) async {
    final limit = (now ?? DateTime.now()).toUtc().subtract(unused);
    final stale = [
      for (final device in _devices.values)
        if ((device.lastSeenAt ?? device.pairedAt).toUtc().isBefore(limit))
          device,
    ];
    if (stale.isEmpty) return const [];
    for (final device in stale) {
      _devices.remove(device.id);
    }
    await _notifyChanged();
    return stale;
  }

  Future<void> rename(String deviceId, String name) async {
    final current = _devices[deviceId];
    final normalized = name.trim();
    if (current == null || normalized.isEmpty || normalized.length > 80) return;
    _devices[deviceId] = current.copyWith(name: normalized);
    await _notifyChanged();
  }

  Future<void> setAdultExplicitAllowed(String deviceId, bool allowed) async {
    final current = _devices[deviceId];
    if (current == null || current.allowAdultExplicit == allowed) return;
    _devices[deviceId] = current.copyWith(allowAdultExplicit: allowed);
    await _notifyChanged();
  }

  bool adultExplicitAllowed(String deviceId) =>
      _devices[deviceId]?.allowAdultExplicit ?? false;

  Future<void> setRemoteControlAllowed(String deviceId, bool allowed) async {
    final current = _devices[deviceId];
    if (current == null || current.allowRemoteControl == allowed) return;
    _devices[deviceId] = current.copyWith(allowRemoteControl: allowed);
    await _notifyChanged();
  }

  bool remoteControlAllowed(String deviceId) =>
      _devices[deviceId]?.allowRemoteControl ?? false;

  /// Whether a paired device may see one of the currently shared libraries.
  /// The absence of an allow-list preserves the original all-libraries
  /// behaviour for existing pairings.
  bool libraryAllowed(String deviceId, String libraryId) {
    final allowed = _devices[deviceId]?.allowedLibraryIds;
    return allowed == null || allowed.contains(libraryId);
  }

  Future<void> setAllowedLibraries(
    String deviceId,
    Set<String>? libraryIds,
  ) async {
    final current = _devices[deviceId];
    if (current case final device?) {
      final normalized = libraryIds
          ?.map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _devices[deviceId] = device.copyWith(allowedLibraryIds: () => normalized);
      await _notifyChanged();
    }
  }

  Future<void> _notifyChanged() async {
    final callback = onChanged;
    if (callback != null) await callback(devices);
  }

  String _randomValue(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String tokenDigest(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static bool _constantTimeEquals(String actual, String expected) {
    final left = utf8.encode(actual);
    final right = utf8.encode(expected);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var index = 0; index < length; index++) {
      difference |=
          (index < left.length ? left[index] : 0) ^
          (index < right.length ? right[index] : 0);
    }
    return difference == 0;
  }
}
