import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../playback/library_playback.dart';

/// Installation-local proof of the exact checkpoint acknowledged durably by
/// its owner. No titles, chapter text, file paths or pairing credentials.
final class OfflineCheckpointReceipt {
  const OfflineCheckpointReceipt({
    required this.vaultId,
    required this.sourceId,
    required this.peerServerId,
    required this.peerLibraryId,
    required this.deviceId,
    required this.workId,
    required this.fingerprint,
    required this.confirmedAt,
    this.peerCertificatePin = '',
  });
  final String vaultId,
      sourceId,
      peerServerId,
      peerLibraryId,
      deviceId,
      workId,
      fingerprint;
  final DateTime confirmedAt;
  final String peerCertificatePin;

  static String fingerprintOf(LibraryPlaybackProgress progress) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            progress.workId,
            progress.fileId,
            progress.position.withFileId(progress.fileId).syncKey,
            progress.finished,
            progress.deviceId,
            progress.revision,
            progress.updatedAt.toUtc().millisecondsSinceEpoch,
            progress.operationId,
            progress.checkpoint,
          ]),
        ),
      )
      .toString();

  bool matches(
    LibraryPlaybackProgress progress, {
    required String currentDeviceId,
  }) =>
      progress.checkpoint &&
      progress.deviceId == currentDeviceId &&
      deviceId == currentDeviceId &&
      progress.workId == workId &&
      fingerprint == fingerprintOf(progress);

  Map<String, Object?> toJson() => {
    'format_version': 1,
    'vault_id': vaultId,
    'source_id': sourceId,
    'peer_server_id': peerServerId,
    'peer_library_id': peerLibraryId,
    'device_id': deviceId,
    'work_id': workId,
    'fingerprint': fingerprint,
    'confirmed_at': confirmedAt.toUtc().toIso8601String(),
    'peer_certificate_pin': peerCertificatePin,
  };

  static OfflineCheckpointReceipt fromJson(Object? value) {
    if (value is! Map ||
        value['format_version'] != 1 ||
        [
          'vault_id',
          'source_id',
          'peer_server_id',
          'peer_library_id',
          'device_id',
          'work_id',
          'fingerprint',
        ].any(
          (key) =>
              value[key] is! String ||
              (value[key] as String).isEmpty ||
              (value[key] as String).length > 512,
        )) {
      throw const FormatException('Ungültige Offline-Bestätigung.');
    }
    final at = DateTime.tryParse('${value['confirmed_at'] ?? ''}');
    if (at == null ||
        value['peer_certificate_pin'] is! String ||
        (value['peer_certificate_pin'] as String).length > 256 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['fingerprint'] as String)) {
      throw const FormatException('Ungültige Offline-Bestätigung.');
    }
    return OfflineCheckpointReceipt(
      vaultId: value['vault_id'] as String,
      sourceId: value['source_id'] as String,
      peerServerId: value['peer_server_id'] as String,
      peerLibraryId: value['peer_library_id'] as String,
      deviceId: value['device_id'] as String,
      workId: value['work_id'] as String,
      fingerprint: value['fingerprint'] as String,
      confirmedAt: at.toUtc(),
      peerCertificatePin: value['peer_certificate_pin'] as String,
    );
  }
}
