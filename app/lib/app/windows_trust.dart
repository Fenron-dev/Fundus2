import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

const _windowsTrustChannel = MethodChannel('dev.fundus/windows_trust');

final class WindowsTrustReport {
  const WindowsTrustReport({
    required this.received,
    required this.installed,
    this.error,
  });

  final int received;
  final int installed;
  final String? error;
}

/// Adds the roots and intermediate issuers trusted by Windows to Dart's HTTPS
/// context.
///
/// Dart uses its bundled Mozilla roots on Windows instead of the Windows
/// certificate stores. That makes HTTPS fail when a legitimate local root
/// (for example a company or antivirus inspection certificate) is installed
/// in Windows and works in browsers. We add those roots and intermediate CAs
/// without accepting a certificate Windows itself does not trust;
/// certificate and host checks remain enabled.
Future<WindowsTrustReport?> installWindowsTrustedRoots() async {
  if (!Platform.isWindows) return null;
  final List<Object?>? roots;
  try {
    roots = await loadWindowsCertificatesWithRetry(
      () => _windowsTrustChannel.invokeListMethod<Object?>('rootCertificates'),
    );
  } on Object catch (error) {
    return WindowsTrustReport(
      received: 0,
      installed: 0,
      error: error.runtimeType.toString(),
    );
  }
  if (roots == null) {
    return const WindowsTrustReport(received: 0, installed: 0);
  }
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
    } on Object {
      // One malformed or unsupported entry must not discard the other roots.
    }
  }
  return WindowsTrustReport(received: roots.length, installed: installed);
}

/// Waits until the native runner has installed its channel.
///
/// `FlutterViewController` starts Dart before FlutterWindow can finish
/// registering app-owned method channels. On a fast Windows start the first
/// call can therefore legitimately receive [MissingPluginException]. Waiting
/// a few event-loop turns is enough; other platform errors remain failures.
Future<List<Object?>?> loadWindowsCertificatesWithRetry(
  Future<List<Object?>?> Function() load, {
  int attempts = 40,
  Duration retryDelay = const Duration(milliseconds: 25),
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await load();
    } on MissingPluginException {
      if (attempt + 1 >= attempts) rethrow;
      await Future<void>.delayed(retryDelay);
    }
  }
  return null;
}
