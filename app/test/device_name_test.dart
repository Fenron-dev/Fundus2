import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/settings/settings_screen.dart';
import 'package:fundus_design/fundus_design.dart';

/// The name this device answers to.
///
/// It reaches the other side at pairing and stands in its device list, so a
/// name that quietly fails to save is a device nobody can tell apart from the
/// next one.
void main() {
  late AppSettings settings;
  late LibraryController library;

  setUp(() {
    settings = AppSettings.inMemory();
    library = LibraryController();
  });

  tearDown(() => library.dispose());

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          scanner: const NoPairingScanner(),
          child: const Scaffold(
            body: SettingsScreen(category: 'synchronisation'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ein Name bleibt, auch ohne Eingabetaste', (tester) async {
    await pumpSettings(tester);

    await tester.enterText(
      find.ancestor(
        of: find.text('Gerätename'),
        matching: find.byType(TextField),
      ),
      'Fenrons Tablet',
    );
    // Kein Enter, kein Wechsel des Fokus — auf dem Telefon tippt man einfach
    // weiter. Genau daran ist der Name vorher verlorengegangen.
    await tester.pump();

    expect(settings.deviceName, 'Fenrons Tablet');
  });

  test('ein leeres Feld nimmt dem Gerät nicht den Namen', () async {
    await settings.setDeviceName('Fenrons Handy');
    await settings.setDeviceName('   ');

    expect(settings.deviceName, 'Fenrons Handy');
  });
}
