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
