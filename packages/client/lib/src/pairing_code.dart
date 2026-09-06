import 'dart:convert';

/// The code a Fundus shows when it is willing to be paired with.
///
/// Deliberately the same shape the previous client used, so a code from an
/// existing Fundus still works: a JSON blob carrying where to reach the
/// server, which certificate to expect and a one-time nonce, plus a six-digit
/// PIN the user reads off the other screen. Two channels, because the code
/// alone travels through a QR image that anyone in the room could photograph.
final class FundusPairingCode {
  const FundusPairingCode({
    required this.baseUri,
    required this.serverId,
    required this.certificateFingerprint,
    required this.nonce,
    required this.expiresAt,
    this.serverName,
  });

  final Uri baseUri;
  final String serverId;

  /// The SHA-256 of the server's certificate, lowercase hex. A self-signed
  /// certificate on a home network is normal; pinning is what makes it safe.
  final String certificateFingerprint;
  final String nonce;
  final DateTime expiresAt;
  final String? serverName;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  /// Reads a code, refusing anything that would send credentials somewhere
  /// unintended.
  static FundusPairingCode parse(String source) {
    final Object? value;
    try {
      value = jsonDecode(source.trim());
    } on FormatException {
      throw const FormatException('Das ist kein Fundus-Kopplungscode.');
    }
    if (value is! Map ||
        value['type'] != 'fundus_pairing' ||
        value['version'] != 1) {
      throw const FormatException('Das ist kein Fundus-Kopplungscode.');
    }

    final baseUri = Uri.tryParse('${value['base_url'] ?? ''}');
    final fingerprint = '${value['certificate_sha256'] ?? ''}'.toLowerCase();
    final expiresAt = DateTime.tryParse('${value['expires_at'] ?? ''}');
    final nonce = '${value['nonce'] ?? ''}';

    if (baseUri == null ||
        baseUri.host.isEmpty ||
        // A user info section would send the credentials to a different host
        // than the one shown; a code carrying one is not one to trust.
        baseUri.userInfo.isNotEmpty ||
        (baseUri.scheme != 'https' && baseUri.scheme != 'http') ||
        // Plain HTTP is useful for local test servers, but must never be
        // accepted for a LAN pairing code: the claim request carries the
        // bearer token that protects the whole library.
        (baseUri.scheme == 'http' &&
            !const {'localhost', '127.0.0.1', '::1'}.contains(baseUri.host))) {
      throw const FormatException('Der Kopplungscode nennt keine Adresse.');
    }
    if (!_fingerprintPattern.hasMatch(fingerprint) &&
        baseUri.scheme == 'https') {
      throw const FormatException(
        'Der Kopplungscode nennt kein gültiges Zertifikat.',
      );
    }
    if (nonce.isEmpty || expiresAt == null) {
      throw const FormatException('Der Kopplungscode ist unvollständig.');
    }

    return FundusPairingCode(
      baseUri: baseUri,
      serverId: '${value['server_id'] ?? ''}',
      certificateFingerprint: fingerprint,
      nonce: nonce,
      expiresAt: expiresAt,
      serverName: value['server_name'] is String
          ? value['server_name'] as String
          : null,
    );
  }

  String encode() => jsonEncode({
    'type': 'fundus_pairing',
    'version': 1,
    'base_url': baseUri.toString(),
    'server_id': serverId,
    'server_name': serverName,
    'certificate_sha256': certificateFingerprint,
    'nonce': nonce,
    'expires_at': expiresAt.toUtc().toIso8601String(),
  });
}
