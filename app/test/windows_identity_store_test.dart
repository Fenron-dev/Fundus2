import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/server_identity.dart';
import 'package:fundus_server/fundus_server.dart';

void main() {
  test(
    'Windows replaces paired-device snapshots without a direct write',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-pairing-');
      try {
        final store = ServerIdentityStore(root);
        final device = FundusPairedDevice(
          id: 'phone',
          name: 'Test phone',
          tokenHash: FundusPairingAuthority.tokenDigest('test-token'),
          pairedAt: DateTime.utc(2026),
        );
        await store.savePairedDevices([device]);
        expect((await store.loadPairedDevices()).single.id, 'phone');

        // The second write must replace an existing destination. A Windows
        // rename without the native replacement path fails at this point.
        await store.savePairedDevices(const []);
        expect(await ServerIdentityStore(root).loadPairedDevices(), isEmpty);
        expect(
          await File('${root.path}/paired-devices.json').readAsString(),
          '[]',
        );
        expect(
          root.listSync().where((entry) => entry.path.endsWith('.tmp')),
          isEmpty,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
