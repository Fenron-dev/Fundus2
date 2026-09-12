import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/windows_trust.dart';

void main() {
  test('wartet auf den nativen Windows-Zertifikatskanal', () async {
    var calls = 0;

    final certificates = await loadWindowsCertificatesWithRetry(() async {
      calls++;
      if (calls < 3) throw MissingPluginException();
      return <Object?>[
        Uint8List.fromList([1, 2, 3]),
      ];
    }, retryDelay: Duration.zero);

    expect(calls, 3);
    expect(certificates, hasLength(1));
  });

  test('gibt nach der begrenzten Zahl von Versuchen auf', () async {
    var calls = 0;

    await expectLater(
      loadWindowsCertificatesWithRetry(
        () async {
          calls++;
          throw MissingPluginException();
        },
        attempts: 3,
        retryDelay: Duration.zero,
      ),
      throwsA(isA<MissingPluginException>()),
    );
    expect(calls, 3);
  });
}
