import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Who this device is when another Fundus talks to it.
final class ServerIdentity {
  const ServerIdentity({
    required this.serverId,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.certificateFingerprint,
    required this.pairedDevices,
  });

  final String serverId;
  final String certificatePem;
  final String privateKeyPem;

  /// The SHA-256 of the certificate, as it goes into the pairing code. This
  /// is the whole of the trust: the other side pins it and accepts nothing
  /// else afterwards.
  final String certificateFingerprint;
  final List<FundusPairedDevice> pairedDevices;
}

/// Where the identity of the served side is kept.
///
/// Beside the app's own settings, not in the vault: the private key is this
/// installation's, and a vault folder is shared by definition. Losing it to a
/// reinstall is the right price — a new key means a new pairing, which is
/// exactly what should happen when the machine is no longer the same one.
final class ServerIdentityStore {
  ServerIdentityStore(this.directory);

  static Future<ServerIdentityStore> platformDefault() async {
    final base = await getApplicationSupportDirectory();
    return ServerIdentityStore(Directory(p.join(base.path, 'peer-server')));
  }

  final Directory directory;

  File get _identityFile => File(p.join(directory.path, 'identity.json'));
  File get _certificateFile => File(p.join(directory.path, 'server-cert.pem'));
  File get _privateKeyFile => File(p.join(directory.path, 'server-key.pem'));
  File get _devicesFile => File(p.join(directory.path, 'paired-devices.json'));
  File get _preferencesFile => File(p.join(directory.path, 'sharing.json'));

  /// Reads the identity, making one the first time.
  ///
  /// Generating an RSA key takes a moment, which is why it happens once and
  /// is then kept — a server that made a new certificate on every start would
  /// invalidate every pairing on every start.
  Future<ServerIdentity> loadOrCreate() async {
    await directory.create(recursive: true);
    final serverId = await _serverId() ?? 'fundus-${_randomValue(12)}';
    var certificate = await _read(_certificateFile);
    var privateKey = await _read(_privateKeyFile);
    if (certificate == null || privateKey == null) {
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final private = pair.privateKey as RSAPrivateKey;
      final public = pair.publicKey as RSAPublicKey;
      final request = X509Utils.generateRsaCsrPem(
        const {'CN': 'Fundus', 'O': 'Fundus'},
        private,
        public,
        san: const ['localhost'],
      );
      certificate = X509Utils.generateSelfSignedCertificate(
        private,
        request,
        3650,
        sans: const ['localhost'],
        extKeyUsage: const [ExtendedKeyUsage.SERVER_AUTH],
        serialNumber: List.generate(24, (_) => _random.nextInt(10)).join(),
      );
      privateKey = CryptoUtils.encodeRSAPrivateKeyToPem(private);
      await _certificateFile.writeAsString(certificate, flush: true);
      await _privateKeyFile.writeAsString(privateKey, flush: true);
      await _restrict(_privateKeyFile);
    }
    await _identityFile.writeAsString(
      jsonEncode({'server_id': serverId}),
      flush: true,
    );
    return ServerIdentity(
      serverId: serverId,
      certificatePem: certificate,
      privateKeyPem: privateKey,
      certificateFingerprint: sha256
          .convert(CryptoUtils.getBytesFromPEMString(certificate))
          .toString(),
      pairedDevices: await loadPairedDevices(),
    );
  }

  Future<List<FundusPairedDevice>> loadPairedDevices() async {
    final source = await _read(_devicesFile);
    if (source == null) return const [];
    try {
      final value = jsonDecode(source);
      if (value is! List) return const [];
      return value
          .map(FundusPairedDevice.fromJson)
          .whereType<FundusPairedDevice>()
          .toList(growable: false);
    } on FormatException {
      // A damaged file costs the pairings, never the start.
      return const [];
    }
  }

  Future<void> savePairedDevices(List<FundusPairedDevice> devices) async {
    await directory.create(recursive: true);
    await _devicesFile.writeAsString(
      jsonEncode([for (final device in devices) device.toJson()]),
      flush: true,
    );
  }

  /// Whether the device offered its library the last time it was running.
  Future<bool> loadSharing() async {
    final source = await _read(_preferencesFile);
    if (source == null) return false;
    try {
      final value = jsonDecode(source);
      return value is Map && value['sharing'] == true;
    } on FormatException {
      return false;
    }
  }

  Future<void> saveSharing(bool value) async {
    await directory.create(recursive: true);
    await _preferencesFile.writeAsString(
      jsonEncode({'sharing': value}),
      flush: true,
    );
  }

  Future<String?> _serverId() async {
    final source = await _read(_identityFile);
    if (source == null) return null;
    try {
      final value = jsonDecode(source);
      if (value is Map && value['server_id'] is String) {
        return value['server_id'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static Future<String?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final value = await file.readAsString();
      return value.trim().isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  /// The private key is readable by its owner and nobody else.
  static Future<void> _restrict(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on ProcessException {
      // Not every platform has chmod; the key is still inside the app's own
      // support directory.
    }
  }

  static final _random = Random.secure();

  static String _randomValue(int byteCount) => base64UrlEncode(
    List<int>.generate(byteCount, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');
}
