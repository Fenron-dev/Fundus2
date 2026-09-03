import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app may read the device's storage as files.
///
/// Only Android asks this. A Fundus library is a folder that other tools also
/// write to, so it has to be walked as directories and opened by path — a
/// document picker hands back a tree URI, which the scanner and the archive
/// reader cannot use. On Android 11 and later that means "All files access",
/// and only the system settings can grant it.
abstract interface class StorageAccess {
  /// True where nothing has to be asked at all.
  bool get isRequired;

  Future<bool> isGranted();

  /// Sends the user to the system settings and answers with what they chose.
  Future<bool> request();

  /// Where the device's own storage begins, for a sensible starting folder.
  Future<String?> storageRoot();
}

final class PlatformStorageAccess implements StorageAccess {
  const PlatformStorageAccess();

  static const _channel = MethodChannel('dev.fundus/android_storage_access');

  @override
  bool get isRequired => !kIsWeb && Platform.isAndroid;

  @override
  Future<bool> isGranted() async {
    if (!isRequired) return true;
    try {
      return await _channel.invokeMethod<bool>('isGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // An older build of the app shell without the channel: saying "no"
      // would block the library for good, so the picker is left to try.
      return true;
    }
  }

  @override
  Future<bool> request() async {
    if (!isRequired) return true;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<String?> storageRoot() async {
    if (!isRequired) return null;
    try {
      return await _channel.invokeMethod<String>('storageRoot');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// For every platform that simply has its files: nothing to ask, nothing to
/// answer.
final class OpenStorageAccess implements StorageAccess {
  const OpenStorageAccess();

  @override
  bool get isRequired => false;

  @override
  Future<bool> isGranted() async => true;

  @override
  Future<bool> request() async => true;

  @override
  Future<String?> storageRoot() async => null;
}
