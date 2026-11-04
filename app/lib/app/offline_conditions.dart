import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';

/// Read only while preparing/transferring; no permanent polling or wake lock.
Future<OfflineConditions> readOfflineConditions() async {
  if (!Platform.isAndroid) return const OfflineConditions();
  try {
    final value = await const MethodChannel('dev.fundus/offline_conditions')
        .invokeMapMethod<String, Object?>('read')
        .timeout(const Duration(seconds: 3));
    return OfflineConditions(
      wifi: value?['wifi'] is bool ? value!['wifi'] as bool : null,
      charging: value?['charging'] is bool ? value!['charging'] as bool : null,
    );
  } on Object {
    return const OfflineConditions();
  }
}

/// What stays free beyond a download, so fetching something never fills the
/// phone. The speech model and podcast episodes keep the same distance.
const freeSpaceReserveBytes = 200 * 1024 * 1024;

/// Free bytes where [path] lives, or null where the platform does not say.
///
/// Only Android answers today. A desktop has its own disk and its own way of
/// warning; a phone that fills up silently stops recording photos.
Future<int?> readFreeBytes(String path) async {
  if (!Platform.isAndroid) return null;
  try {
    final value = await const MethodChannel('dev.fundus/offline_conditions')
        .invokeMethod<Object?>('freeBytes', {'path': path})
        .timeout(const Duration(seconds: 3));
    return value is int ? value : null;
  } on Object {
    return null;
  }
}
