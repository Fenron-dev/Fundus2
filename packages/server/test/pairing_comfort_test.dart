import 'package:fundus_server/fundus_server.dart';
import 'package:test/test.dart';

/// Pairing is a door. Whoever sits at the machine hears when it opens, and
/// a device nobody uses any more does not keep its key forever.
void main() {
  test('a successful pairing is announced, a failed one is not', () async {
    final announced = <String>[];
    final authority = FundusPairingAuthority(
      onPaired: (device) => announced.add(device.name),
    );
    final session = authority.begin();
    await expectLater(
      authority.claim(
        nonce: session.nonce,
        pin: session.pin == '000000' ? '111111' : '000000',
        deviceId: 'intruder',
        deviceName: 'Fremd',
      ),
      throwsA(isA<FundusPairingException>()),
    );
    expect(announced, isEmpty);

    await authority.claim(
      nonce: session.nonce,
      pin: session.pin,
      deviceId: 'phone-1',
      deviceName: 'Telefon',
    );
    expect(announced, ['Telefon']);
  });

  test('devices unused for too long are unpaired', () async {
    final now = DateTime.utc(2026, 11, 1);
    final authority = FundusPairingAuthority(
      devices: [
        FundusPairedDevice(
          id: 'old',
          name: 'Altes Telefon',
          tokenHash: FundusPairingAuthority.tokenDigest('old-token'),
          pairedAt: DateTime.utc(2025, 1, 1),
          lastSeenAt: DateTime.utc(2026, 5, 1),
        ),
        FundusPairedDevice(
          id: 'never',
          name: 'Nie benutzt',
          tokenHash: FundusPairingAuthority.tokenDigest('never-token'),
          pairedAt: DateTime.utc(2026, 1, 1),
        ),
        FundusPairedDevice(
          id: 'recent',
          name: 'Tablet',
          tokenHash: FundusPairingAuthority.tokenDigest('recent-token'),
          pairedAt: DateTime.utc(2025, 1, 1),
          lastSeenAt: DateTime.utc(2026, 10, 20),
        ),
      ],
    );

    final removed = await authority.revokeInactive(
      const Duration(days: 90),
      now: now,
    );
    expect(removed.map((device) => device.id).toSet(), {'old', 'never'});
    expect(authority.devices.map((device) => device.id), ['recent']);
    // The old key opens nothing any more.
    expect(authority.authorize('old-token'), isFalse);
    expect(authority.authorize('recent-token'), isTrue);
  });
}
