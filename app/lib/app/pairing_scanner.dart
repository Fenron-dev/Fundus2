import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Reading a pairing code off the other device's screen.
///
/// The code is a line of JSON with a certificate fingerprint in it — thirty
/// seconds of typing on a phone, or one second of holding it up. The camera is
/// the better of the two, but not every platform has one the app can reach, so
/// asking whether it is available comes before offering it.
abstract interface class PairingScanner {
  /// Whether this build can open a camera at all. Windows and Linux cannot.
  bool get isAvailable;

  /// Opens the camera and returns the first code it recognises, or null if the
  /// person closed it again.
  Future<String?> scan(BuildContext context);
}

/// The camera, where there is one.
class CameraPairingScanner implements PairingScanner {
  const CameraPairingScanner();

  @override
  bool get isAvailable => switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  Future<String?> scan(BuildContext context) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => const _ScannerScreen(),
        ),
      );
}

/// No camera, and no pretending otherwise.
class NoPairingScanner implements PairingScanner {
  const NoPairingScanner();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> scan(BuildContext context) async => null;
}

class _ScannerScreen extends StatefulWidget {
  const _ScannerScreen();

  @override
  State<_ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<_ScannerScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  String? _complaint;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Only a real pairing code closes the screen.
  ///
  /// Any other QR code — a WLAN code, a ticket, a poster — would otherwise
  /// end the scan with something the pairing cannot use, and the person would
  /// have to start over without being told why.
  void _found(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      try {
        FundusPairingCode.parse(value);
      } on FormatException {
        setState(() => _complaint = 'Das ist kein Fundus-Kopplungscode.');
        continue;
      }
      _done = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Code scannen'),
        actions: [
          IconButton(
            onPressed: _controller.toggleTorch,
            icon: Icon(FundusIcons.torch, size: FundusIcons.sizeMd),
            tooltip: 'Licht',
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _found),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(FundusSpace.x10),
              child: Text(
                _complaint ??
                    'Halte die Kamera auf den Kopplungscode des anderen '
                        'Geräts. Die PIN wird danach von Hand eingegeben.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _complaint == null ? Colors.white70 : Colors.orange,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
