import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Adds the roots trusted by Windows to Dart's HTTPS context.
///
/// Dart uses its bundled Mozilla roots on Windows instead of the Windows
/// certificate stores. That makes HTTPS fail when a legitimate local root
/// (for example a company or antivirus inspection certificate) is installed
/// in Windows and works in browsers. We add those roots without accepting a
/// certificate Windows itself does not trust; certificate and host checks
/// remain enabled.
Future<int> installWindowsTrustedRoots() async {
  if (!Platform.isWindows) return 0;
  const channel = MethodChannel('dev.fundus/windows_trust');
  final roots = await channel.invokeListMethod<Object?>('rootCertificates');
  if (roots == null) return 0;
  var installed = 0;
  for (final value in roots) {
    if (value is! Uint8List || value.isEmpty) continue;
    final encoded = base64.encode(value);
    final lines = <String>[
      for (var start = 0; start < encoded.length; start += 64)
        encoded.substring(
          start,
          start + 64 > encoded.length ? encoded.length : start + 64,
        ),
    ];
    final pem =
        '-----BEGIN CERTIFICATE-----\n'
        '${lines.join('\n')}\n'
        '-----END CERTIFICATE-----\n';
    try {
      SecurityContext.defaultContext.setTrustedCertificatesBytes(
        utf8.encode(pem),
      );
      installed++;
    } on TlsException {
      // One malformed or unsupported entry must not discard the other roots.
    }
  }
  return installed;
}
