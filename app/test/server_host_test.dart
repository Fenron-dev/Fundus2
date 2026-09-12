import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/server_host.dart';
import 'package:fundus/data/server_identity.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';

/// The served side, over a real socket with the certificate it made itself.
///
/// This is the one thing that cannot be faked convincingly: pairing hands out
/// a certificate fingerprint, and everything afterwards has to be refused
/// unless the certificate is that one. So the test connects for real — TLS,
/// pinning, pairing, and one round of syncing.
void main() {
  late Directory temporary;
  late ServerIdentityStore store;
  late LibraryController library;
  late AppSettings settings;
  late ServerHostController host;
  late String workId;
  late String fileId;
  late Directory root;

  setUpAll(() async {
    // Making an RSA key takes a moment; one is enough for every test here.
    temporary = await Directory.systemTemp.createTemp('fundus-host-');
    store = ServerIdentityStore(Directory('${temporary.path}/identity'));
    await store.loadOrCreate();
  });

  tearDownAll(() async => temporary.delete(recursive: true));

  setUp(() async {
    root = await Directory(
      '${temporary.path}/vault-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
    final vault = await FundusLibrary.create(root);
    await for (final _ in vault.index()) {}
    workId = vault.listWorks().single.id;
    fileId = vault.playbackTracks(workId).single.fileId;
    vault.close();

    library = LibraryController();
    await library.open(root);
    settings = AppSettings.inMemory();
    host = ServerHostController(
      settings: settings,
      library: library,
      identityStore: store,
    );
  });

  tearDown(() async {
    await host.stop(remember: false);
    host.dispose();
    library.dispose();
  });

  test('die Kennung bleibt dieselbe, auch nach einem Neustart', () async {
    final first = await store.loadOrCreate();
    final again = await store.loadOrCreate();

    expect(again.serverId, first.serverId);
    expect(again.certificateFingerprint, first.certificateFingerprint);
    expect(again.certificateFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('ohne geöffnete Bibliothek gibt es nichts freizugeben', () async {
    final empty = ServerHostController(
      settings: settings,
      library: LibraryController(),
      identityStore: store,
    );
    addTearDown(empty.dispose);

    await empty.start(remember: false);

    expect(empty.isRunning, isFalse);
    expect(empty.failure, contains('keine Bibliothek'));
  });

  test('ein gekoppeltes Gerät gleicht über TLS ab', () async {
    await host.start(remember: false);
    expect(host.failure, isNull);
    expect(host.isRunning, isTrue);

    final identity = await store.loadOrCreate();
    host.beginPairing();
    final session = host.pairingSession;
    if (session == null) {
      // Ohne Netzwerkadresse gibt es nichts anzubieten, und genau das gehört
      // geprüft: kein Code ohne einen Weg dorthin.
      expect(host.addresses, isEmpty);
      expect(host.pairingCode, isNull);
      return;
    }

    expect(
      FundusPairingCode.parse(host.pairingCode!).certificateFingerprint,
      identity.certificateFingerprint,
    );
    final code = _loopback(host, session, identity);

    final claimed = await FundusRemoteClient.claim(
      code: code,
      pin: session.pin,
      deviceId: 'anderes-geraet',
      deviceName: 'Telefon',
    );
    expect(claimed.token, isNotEmpty);
    expect(host.pairedDevices.single.name, 'Telefon');

    // Und mit dem Token lässt sich abgleichen, gegen genau dieses Zertifikat.
    final client = FundusRemoteClient(
      baseUri: code.baseUri,
      token: claimed.token,
      certificateFingerprint: code.certificateFingerprint,
    );
    addTearDown(client.close);

    final libraries = await client.libraries();
    expect(libraries.single.id, library.library!.manifest.libraryId);

    await client.saveProgress(
      libraryId: libraries.single.id,
      workId: workId,
      fileId: fileId,
      position: const MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: 90,
      ),
      finished: false,
      deviceId: 'anderes-geraet',
    );
    library.refresh();
    expect(
      library.library!.loadProgress(workId)!.position.numericValue,
      closeTo(90, 0.001),
    );

    // Ein entzogener Zugang gilt sofort nicht mehr.
    await host.revoke('anderes-geraet');
    await expectLater(
      client.libraries(),
      throwsA(
        isA<FundusRemoteException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
  });

  test('die Freigabe folgt der Bibliothek, die geöffnet ist', () async {
    await host.start(remember: false);
    host.beginPairing();
    final session = host.pairingSession;
    if (session == null) return; // Kein Netz — siehe oben.

    final code = _loopback(host, session, await store.loadOrCreate());
    final claimed = await FundusRemoteClient.claim(
      code: code,
      pin: session.pin,
      deviceId: 'anderes-geraet',
      deviceName: 'Telefon',
    );
    final client = FundusRemoteClient(
      baseUri: code.baseUri,
      token: claimed.token,
      certificateFingerprint: code.certificateFingerprint,
    );
    addTearDown(client.close);
    final libraryId = (await client.libraries()).single.id;
    expect((await client.works(libraryId)).single.id, workId);

    // Dieselbe Bibliothek noch einmal geöffnet ist eine neue Instanz, und
    // die alte ist geschlossen. Genau hier stand die Freigabe bisher auf
    // einer geschlossenen Datenbank: koppeln ging, erreichbar war nichts.
    await library.open(root);
    expect(library.isOpen, isTrue);

    expect((await client.libraries()).single.id, libraryId);
    expect((await client.works(libraryId)).single.id, workId);

    // Die Kopplung liegt beim Ausweis dieses Geräts und überlebt den Test —
    // die folgenden Prüfungen gehen von einer leeren Liste aus.
    await host.revoke('anderes-geraet');
  });

  test('ein Server stellt mehrere ausgewählte Bibliotheken bereit', () async {
    final extra = Directory(
      '${temporary.path}/extra-${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      if (await extra.exists()) await extra.delete(recursive: true);
    });
    final extraWork = Directory('${extra.path}/HHH/Beispiel');
    await extraWork.create(recursive: true);
    await File(
      '${extraWork.path}/01 - Einstieg.mp3',
    ).writeAsBytes(List.filled(64, 2));
    final extraVault = await FundusLibrary.create(extra);
    await for (final _ in extraVault.index()) {}
    extraVault.close();

    await host.addLibrary(extra.path, name: 'HHH');
    await host.start(remember: false);
    expect(host.failure, isNull);
    expect(host.libraries, hasLength(2));
    expect(host.libraries.map((entry) => entry.name), containsAll(['HHH']));

    addTearDown(() => host.revoke('mehrbibliotheken-geraet'));
    host.beginPairing();
    final session = host.pairingSession;
    if (session == null) return; // Kein Netz — siehe die übrigen Host-Tests.
    final code = _loopback(host, session, await store.loadOrCreate());
    final claimed = await FundusRemoteClient.claim(
      code: code,
      pin: session.pin,
      deviceId: 'mehrbibliotheken-geraet',
      deviceName: 'Telefon',
    );
    final client = FundusRemoteClient(
      baseUri: code.baseUri,
      token: claimed.token,
      certificateFingerprint: code.certificateFingerprint,
    );
    addTearDown(client.close);

    final libraries = await client.libraries();
    expect(libraries, hasLength(2));
    expect(libraries.map((entry) => entry.name), containsAll(['HHH']));

    // Opening the background vault in the desktop must not drop the former
    // active vault from the same server. This used to leave its already
    // mirrored works visible on mobile but marked as unreachable.
    await library.open(extra);
    await _eventually(
      () =>
          host.isRunning &&
          !host.isReconcilingLibraries &&
          host.libraries.where((item) => item.shared).length == 2,
    );
    final afterSwitch = await client.libraries();
    expect(afterSwitch, hasLength(2));
    for (final offered in afterSwitch) {
      expect(await client.works(offered.id), isNotEmpty);
    }
  });

  test(
    'eingeschaltet ohne Bibliothek beginnt sie, sobald eine da ist',
    () async {
      final waiting = LibraryController();
      final later = ServerHostController(
        settings: settings,
        library: waiting,
        identityStore: store,
      );
      addTearDown(() async {
        await later.stop(remember: false);
        later.dispose();
        waiting.dispose();
      });

      await later.start(remember: false);
      expect(later.isRunning, isFalse);

      await waiting.open(root);
      // Der Wunsch galt dem Gerät: die Freigabe zieht nach.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(later.isRunning, isTrue, reason: later.failure);
    },
  );

  test('ein anderes Zertifikat wird nicht angenommen', () async {
    await host.start(remember: false);
    host.beginPairing();
    final session = host.pairingSession;
    if (session == null) return; // Kein Netz — siehe oben.

    final code = _loopback(host, session, await store.loadOrCreate());
    await expectLater(
      FundusRemoteClient.claim(
        code: FundusPairingCode(
          baseUri: code.baseUri,
          serverId: code.serverId,
          // Dasselbe Gerät, ein anderes Zertifikat: das ist der Fall, den es
          // zu bemerken gilt.
          certificateFingerprint: 'f' * 64,
          nonce: code.nonce,
          expiresAt: code.expiresAt,
        ),
        pin: session.pin,
        deviceId: 'anderes-geraet',
        deviceName: 'Telefon',
      ),
      throwsA(isA<FundusRemoteException>()),
    );
    expect(host.pairedDevices, isEmpty);
  });

  test('eine falsche PIN koppelt nicht', () async {
    await host.start(remember: false);
    host.beginPairing();
    if (host.pairingSession == null) return; // Kein Netz — siehe oben.

    final sync = SyncController(settings: settings, library: library);
    addTearDown(sync.dispose);

    final code = _loopback(
      host,
      host.pairingSession!,
      await store.loadOrCreate(),
    );
    expect(await sync.pair(code: code.encode(), pin: '000000'), isFalse);
    expect(host.pairedDevices, isEmpty);
    expect(sync.peers, isEmpty);
  });

  test(
    'die Freigabe wird gemerkt und beim nächsten Start wieder geöffnet',
    () async {
      await host.start();
      expect(host.isRunning, isTrue);

      final again = ServerHostController(
        settings: settings,
        library: library,
        identityStore: store,
      );
      addTearDown(() async {
        await again.stop(remember: false);
        again.dispose();
      });
      await host.stop(remember: false);
      await again.restore();

      expect(again.isRunning, isTrue, reason: again.failure);

      await again.stop();
      final third = ServerHostController(
        settings: settings,
        library: library,
        identityStore: store,
      );
      addTearDown(third.dispose);
      await third.restore();
      expect(third.isRunning, isFalse);
    },
  );

  test(
    'gekoppelte Geräte sind auch bei ausgeschaltetem Server sichtbar',
    () async {
      final ownRoot = await Directory.systemTemp.createTemp('fundus-pairs-');
      addTearDown(() => ownRoot.delete(recursive: true));
      final ownStore = ServerIdentityStore(ownRoot);
      await ownStore.loadOrCreate();
      await ownStore.saveSharing(false);
      await ownStore.savePairedDevices([
        FundusPairedDevice(
          id: 'telefon',
          name: 'S21 FE',
          tokenHash: 'hash',
          pairedAt: DateTime.utc(2026, 9, 12),
          allowedLibraryIds: const {'familie'},
        ),
      ]);
      final restored = ServerHostController(
        settings: settings,
        library: library,
        identityStore: ownStore,
      );
      addTearDown(restored.dispose);

      await restored.restore();

      expect(restored.isRunning, isFalse);
      expect(restored.pairedDevices.single.name, 'S21 FE');
      expect(restored.pairedDevices.single.allowedLibraryIds, {'familie'});
    },
  );
}

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Bedingung wurde nicht rechtzeitig erfüllt.');
}

/// The same invitation, pointing at the loopback.
///
/// The server listens on every interface, and the address in the real code is
/// the one another device would use — which a build machine has no way to
/// reach itself. The certificate, the nonce and the PIN are the real ones, so
/// what is under test is untouched.
FundusPairingCode _loopback(
  ServerHostController host,
  FundusPairingSession session,
  ServerIdentity identity,
) => FundusPairingCode(
  baseUri: Uri.parse('https://127.0.0.1:${host.addresses.first.port}'),
  serverId: host.serverId,
  certificateFingerprint: identity.certificateFingerprint,
  nonce: session.nonce,
  expiresAt: session.expiresAt,
  serverName: 'Prüfstand',
);
