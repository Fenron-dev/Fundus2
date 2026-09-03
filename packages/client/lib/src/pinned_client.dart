import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An HTTP client that trusts exactly one certificate.
///
/// A Fundus on the home network serves HTTPS with a certificate it made
/// itself: there is no authority that could vouch for a machine at
/// 192.168.x.x, and asking a person to install a CA is not a thing to ask.
/// Pinning is the honest version of the same trust — the pairing code names
/// the certificate, and from then on that exact certificate is the only one
/// accepted for that peer.
///
/// The context is built **without** the platform's trusted roots, so the
/// check below runs for every connection rather than only for the ones the
/// system already rejects: a certificate a public authority happens to have
/// issued is still not the one from the pairing code.
http.Client pinnedHttpClient(String certificateFingerprint) {
  final expected = certificateFingerprint.trim().toLowerCase();
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = (certificate, host, port) =>
        _fingerprintOf(certificate) == expected;
  return IOClient(client);
}

String _fingerprintOf(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();
