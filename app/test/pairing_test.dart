import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/pairing_scanner.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/settings/settings_screen.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Handing a pairing code over without typing it.
///
/// The code is a line of JSON with a certificate fingerprint in it. Reading it
/// off a screen and into a phone by hand is the part that made pairing feel
/// like work, so it goes through the camera — and everything here is about
/// that path holding up.
void main() {
  late AppSettings settings;
  late LibraryController library;

  setUp(() {
    settings = AppSettings.inMemory();
    library = LibraryController();
  });

  tearDown(() => library.dispose());

  Future<void> pumpSettings(
    WidgetTester tester, {
    required PairingScanner scanner,
  }) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          scanner: scanner,
          child: const Scaffold(
            body: SettingsScreen(category: 'synchronisation'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('der Kopplungscode passt in einen QR-Code, den man scannen kann', () {
    // So lang, wie er im Betrieb wirklich wird: ein voller Fingerabdruck,
    // eine Adresse mit Port und ein Gerätename, den jemand vergeben hat.
    final code = FundusPairingCode(
      baseUri: Uri.parse('https://192.168.178.42:47891'),
      serverId: 'a3f1c9d2-7e64-4b18-9c0a-51d3e7b28f60',
      certificateFingerprint: 'ab12cd34' * 8,
      nonce: 'n7Qk2ZpW9sVx4LmT',
      expiresAt: DateTime.utc(2026, 9, 3, 15, 40),
      serverName: 'MacBook Pro von Fenron',
    ).encode();

    final qr = QrValidator.validate(
      data: code,
      errorCorrectionLevel: QrErrorCorrectLevel.L,
    );

    expect(qr.status, QrValidationStatus.valid);
    // Ein QR-Code über Version 15 wird so feinkörnig, dass ihn eine
    // Handykamera aus Armlänge nicht mehr sicher liest.
    expect(qr.qrCode!.typeNumber, lessThanOrEqualTo(15));
  });

  testWidgets('ein gescannter Code landet im Feld, der Cursor in der PIN', (
    tester,
  ) async {
    final code =
        '{"type":"fundus_pairing","version":1,'
        '"base_url":"https://192.168.178.42:47891",'
        '"server_id":"server-1","certificate_sha256":"${'a' * 64}",'
        '"nonce":"abc","expires_at":"2030-01-01T00:00:00Z"}';

    await pumpSettings(tester, scanner: _FakeScanner(code));
    await tester.tap(find.text('QR-Code vom Server scannen'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .map((field) => field.controller?.text)
          .contains(code),
      isTrue,
    );
    // Danach fehlt nur noch die PIN — und das Feld dafür steht bereit.
    final pin = tester.widget<TextField>(
      find.ancestor(of: find.text('PIN'), matching: find.byType(TextField)),
    );
    expect(pin.focusNode?.hasFocus, isTrue);
  });

  testWidgets('ohne Kamera wird auch kein Scannen angeboten', (tester) async {
    await pumpSettings(tester, scanner: const NoPairingScanner());

    expect(find.text('QR-Code scannen'), findsNothing);
    // Der Weg über die Zwischenablage bleibt, sonst gäbe es gar keinen.
    expect(find.widgetWithText(FilledButton, 'Koppeln'), findsOneWidget);
  });

  testWidgets('Gerät und Kopplung stehen auf einer Seite', (tester) async {
    await settings.setDeviceName('MacBook');
    await pumpSettings(tester, scanner: const NoPairingScanner());

    // Was früher „Server & Geräte" war, steht jetzt dort, wo es hingehört.
    expect(find.text('Geräte & Abgleich'), findsOneWidget);
    expect(find.text('Dieses Gerät'), findsOneWidget);
    expect(find.text('MacBook'), findsOneWidget);
    expect(find.text('Dieses Gerät freigeben'), findsOneWidget);
    expect(find.text('Von diesem Gerät verwendete Server'), findsOneWidget);
  });
}

/// A camera that always finds the same code.
class _FakeScanner implements PairingScanner {
  const _FakeScanner(this.code);

  final String code;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> scan(BuildContext context) async => code;
}
