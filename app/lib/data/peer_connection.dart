/// A Fundus this device has been paired with.
///
/// The token is a credential this installation earned, so it lives with the
/// device and not in the vault: `.library/` and `_fundus/` travel with the
/// folder, and a bearer token in a shared folder is a bearer token everyone
/// with the folder has. The price is that a reinstall costs the pairing —
/// which is the right price for a credential.
final class PeerConnection {
  const PeerConnection({
    required this.serverId,
    required this.name,
    required this.baseUrl,
    required this.token,
    this.certificateFingerprint = '',
    this.libraryId = '',
    this.lastSyncAt,
    this.lastResult,
  });

  factory PeerConnection.fromJson(Map<String, Object?> value) => PeerConnection(
    serverId: '${value['server_id'] ?? ''}',
    name: '${value['name'] ?? 'Fundus'}',
    baseUrl: '${value['base_url'] ?? ''}',
    token: '${value['token'] ?? ''}',
    certificateFingerprint: '${value['certificate_sha256'] ?? ''}',
    libraryId: '${value['library_id'] ?? ''}',
    lastSyncAt: DateTime.tryParse('${value['last_sync_at'] ?? ''}'),
    lastResult: value['last_result'] is String
        ? value['last_result'] as String
        : null,
  );

  final String serverId;
  final String name;
  final String baseUrl;
  final String token;

  /// The certificate this peer is allowed to answer with. A Fundus on the
  /// home network signs its own, so this — taken from the pairing code — is
  /// what stands in for an authority.
  final String certificateFingerprint;

  /// Which library over there answers for the vault open here. Learned on the
  /// first sync and kept, so later rounds do not have to ask again.
  final String libraryId;
  final DateTime? lastSyncAt;
  final String? lastResult;

  Uri get baseUri => Uri.parse(baseUrl);

  PeerConnection copyWith({
    String? name,
    String? libraryId,
    DateTime? lastSyncAt,
    String? lastResult,
  }) => PeerConnection(
    serverId: serverId,
    name: name ?? this.name,
    baseUrl: baseUrl,
    token: token,
    certificateFingerprint: certificateFingerprint,
    libraryId: libraryId ?? this.libraryId,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastResult: lastResult ?? this.lastResult,
  );

  Map<String, Object?> toJson() => {
    'server_id': serverId,
    'name': name,
    'base_url': baseUrl,
    'token': token,
    'certificate_sha256': certificateFingerprint,
    'library_id': libraryId,
    'last_sync_at': lastSyncAt?.toUtc().toIso8601String(),
    'last_result': lastResult,
  };
}
