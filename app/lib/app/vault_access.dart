import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fundus_log.dart';

/// Permission to read the library folder, across restarts.
///
/// On macOS and iOS an app only reaches a folder somebody picked in the open
/// dialog, and only until it quits. What survives is a *bookmark*: a token
/// made while the access is still granted, kept, and handed back to the
/// system on the next start. Without one the vault under
/// `/Volumes/…` is unreachable the moment the app is closed and opened again
/// — the entry in the recent list is there, and opening it fails.
///
/// Behind an interface because the other platforms have nothing of the kind
/// and a test must not need a window server.
abstract interface class VaultAccess {
  /// Keeps the permission this session has, for the next one.
  Future<void> remember(String path);

  /// Asks for the kept permission back. False when there is none, or when the
  /// system refuses it — the caller then falls back to the open dialog.
  Future<bool> unlock(String path);

  /// Whether this platform needs any of it at all.
  bool get isRequired;
}

/// Does nothing, correctly: Linux, Windows and Android have no such fence.
final class OpenVaultAccess implements VaultAccess {
  const OpenVaultAccess();

  @override
  bool get isRequired => false;

  @override
  Future<void> remember(String path) async {}

  @override
  Future<bool> unlock(String path) async => true;
}

/// The real thing, over the channel the macOS runner already carries.
final class SecurityScopedVaultAccess implements VaultAccess {
  SecurityScopedVaultAccess({
    required this.read,
    required this.write,
    MethodChannel channel = const MethodChannel(
      'dev.fundus/security_scoped_bookmarks',
    ),
  }) : _channel = channel;

  /// The stored bookmarks, by folder. Kept in the app's settings rather than
  /// in the vault: it is permission for *this* machine to reach that folder,
  /// which means nothing on any other.
  final Map<String, String> Function() read;
  final Future<void> Function(Map<String, String>) write;

  final MethodChannel _channel;

  static bool get platformNeedsIt =>
      !kIsWeb && (Platform.isMacOS || Platform.isIOS);

  @override
  bool get isRequired => true;

  @override
  Future<void> remember(String path) async {
    try {
      final bookmark = await _channel.invokeMethod<String>('create', {
        'path': path,
      });
      if (bookmark == null || bookmark.isEmpty) return;
      await write({...read(), path: bookmark});
    } on Object catch (failure) {
      // A folder without a bookmark still works for as long as the app runs.
      FundusLog.instance.warn('vault.bookmark', {'error': '$failure'});
    }
  }

  @override
  Future<bool> unlock(String path) async {
    final bookmark = read()[path];
    if (bookmark == null) return false;
    try {
      final opened = await _channel.invokeMethod<String>('startAccess', {
        'bookmark': bookmark,
      });
      return opened != null;
    } on Object catch (failure) {
      FundusLog.instance.warn('vault.unlock', {'error': '$failure'});
      return false;
    }
  }
}
