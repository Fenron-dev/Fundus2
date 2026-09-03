import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fundus2 next to Fundus, not on top of it.
///
/// The old client is `dev.fundus.fundus` and stays in service while this one
/// is built. Both systems identify an installed app by that string — Android
/// by the application id, macOS by the bundle identifier — so sharing it means
/// installing one over the other, taking its data with it. These are the
/// places where that string is decided, and nothing here may drift back.
void main() {
  const legacyId = 'dev.fundus.fundus';
  const ourId = 'dev.fundus.fundus2';

  test('die Android-App trägt eine eigene Paketkennung', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(gradle, contains('applicationId = "$ourId"'));
    expect(gradle, contains('namespace = "$ourId"'));
    expect(gradle, isNot(contains('"$legacyId"')));
  });

  test('die macOS-App trägt eine eigene Bündelkennung und einen Namen', () {
    final config = File(
      'macos/Runner/Configs/AppInfo.xcconfig',
    ).readAsStringSync();

    expect(config, contains('PRODUCT_BUNDLE_IDENTIFIER = $ourId'));
    // Auch der Name: zwei „fundus.app" im Programme-Ordner sind eine Datei.
    expect(config, contains('PRODUCT_NAME = Fundus2'));
  });

  test('der Startbildschirm nennt beide auseinander', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:label="Fundus 2"'));
  });

  test('auch Linux bekommt eine eigene Kennung', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('set(APPLICATION_ID "$ourId")'));
  });
}
