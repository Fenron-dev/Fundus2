import 'dart:io';

import 'package:flutter/services.dart';

/// What this device is called before anyone renames it.
///
/// „Android-Gerät" was a placeholder that behaved like a name: a phone and a
/// tablet both carried it, and in a list of paired devices they were the same
/// entry twice. Every platform already knows what it is called — Android from
/// the name in its own settings, the desktops from their host name — so ask
/// rather than invent.
const _channel = MethodChannel('dev.fundus/device');

Future<String> platformDeviceName() async {
  if (Platform.isAndroid) {
    try {
      final name = await _channel.invokeMethod<String>('name');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } on PlatformException {
      // An old build without the channel still gets a name, just a duller one.
    } on MissingPluginException {
      // Same in a test, where there is no Android at the other end.
    }
    return 'Android-Gerät';
  }
  final host = Platform.localHostname.trim();
  if (host.isNotEmpty) {
    // macOS reports „MacBook-von-Fenron.local"; the suffix says nothing.
    final trimmed = host.endsWith('.local')
        ? host.substring(0, host.length - '.local'.length)
        : host;
    return trimmed.replaceAll('-', ' ');
  }
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isWindows) return 'Windows-PC';
  if (Platform.isLinux) return 'Linux-Rechner';
  return 'Dieses Gerät';
}
