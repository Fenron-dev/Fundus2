import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_discovery.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus/data/server_identity.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Der Server ist umgezogen, die Kopplung gilt weiter.
///
/// Der Router vergibt die Adressen per DHCP. Nach einem Neustart hat derselbe
/// Rechner eine andere, und das Telefon klopft an die falsche Tür — bisher bis
/// zum erneuten Koppeln, wobei die Offline-Kopien verloren gingen.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late HttpServer socket;
  late ServerIdentity identity;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraries peers;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-umzug-e2e-');
    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01.mp3').writeAsBytes(List.filled(64, 3));
    theirs = await FundusLibrary.create(source);
    await theirs.index().drain<void>();

    identity = await ServerIdentityStore(
      Directory('${temporary.path}/ausweis'),
    ).loadOrCreate();
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: identity.serverId,
        serverName: 'Mac',
        registry: FundusLibraryRegistry()..register(theirs, name: 'Hörbücher'),
      ).handler,
      InternetAddress.loopbackIPv4,
      0,
      securityContext: context,
    );

    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    peers.dispose();
    library.dispose();
    await socket.close(force: true);
    theirs.close();
    await temporary.delete(recursive: true);
  });

  /// Eine Adresse, an der niemand antwortet.
  Future<int> totePortnummer() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  void buildPeers({PeerAddressDiscovery? discovery}) {
    peers = PeerLibraries(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/speicher'),
      discovery: discovery,
      connect: (peer) => FundusRemoteClient(
        baseUri: peer.baseUri,
        token: peer.token,
        certificateFingerprint: peer.certificateFingerprint.isEmpty
            ? null
            : peer.certificateFingerprint,
      ),
    );
  }

  test(
    'ein umgezogener Server wird gefunden und die Adresse gemerkt',
    () async {
      // Die gespeicherte Adresse zeigt auf einen Port, an dem niemand mehr
      // horcht — sofort abgewiesen, so wie bei einem Server, der umgezogen oder
      // neu gestartet ist. Gesucht wird dann auch auf dem Port, den ein
      // Fundus-Server bevorzugt.
      final tot = await totePortnummer();
      final peer = PeerConnection(
        serverId: identity.serverId,
        name: 'Mac',
        baseUrl: 'https://127.0.0.1:$tot',
        token: 'geheim',
        certificateFingerprint: identity.certificateFingerprint,
      );
      await settings.savePeer(peer);

      buildPeers(
        discovery: PeerAddressDiscovery(
          // Im Betrieb kommen die Kandidaten aus der Ankündigung des Servers;
          // hier werden sie gesetzt, damit der Test kein Multicast braucht.
          candidates: (_) async => [(host: '127.0.0.1', port: socket.port)],
          probeTimeout: const Duration(seconds: 2),
        ),
      );

      final verbunden = await peers.connect(peer, mirror: true);

      expect(verbunden, isTrue, reason: 'über die neue Adresse gefunden');
      expect(
        settings.peers.single.baseUrl,
        'https://127.0.0.1:${socket.port}',
        reason: 'die neue Adresse wird behalten',
      );
      // Und was die Kopplung ausmacht, bleibt unangetastet.
      expect(settings.peers.single.token, 'geheim');
      expect(
        settings.peers.single.certificateFingerprint,
        identity.certificateFingerprint,
      );
      expect(settings.peers.single.serverId, identity.serverId);
    },
  );

  // „Ohne Ausweis wird nicht gesucht" steht bewusst nicht hier, sondern in
  // `peer_discovery_test.dart`: dort wird dieselbe Regel direkt geprüft, ohne
  // dass ein Client erst dreimal in ein Zeitlimit laufen muss. Der Weg durch
  // `PeerLibraries` dauerte damit 25 Sekunden je Lauf und belegte nichts, was
  // die kürzere Prüfung nicht schon belegt.
}
