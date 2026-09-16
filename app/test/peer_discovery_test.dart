import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_discovery.dart';
import 'package:fundus/data/server_identity.dart';

/// Einen umgezogenen Server wiederfinden.
///
/// Der Router vergibt die Adressen per DHCP; nach einem Neustart hat derselbe
/// Rechner eine andere. Die Kopplung gilt weiter — nur klopft das Telefon an
/// die falsche Tür. Der Ausweis aus dem Kopplungscode ist dabei der Anker:
/// wer ihn nicht vorweisen kann, ist nicht dieser Server, auch wenn er dessen
/// Kennung behauptet.
void main() {
  late Directory temporary;
  late ServerIdentity identity;
  late HttpServer socket;
  late ServerIdentity fremde;
  late HttpServer fremderSocket;

  /// Ein Server, der auf `/health` antwortet wie Fundus.
  Future<HttpServer> serve(ServerIdentity who, {int status = 200}) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(who.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(who.privateKeyPem));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'status': status == 200 ? 'ok' : 'unavailable',
            'server_id': who.serverId,
            'api_version': 1,
          }),
        );
      request.response.close();
    }, onError: (Object _) {});
    return server;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-umzug-');
    identity = await ServerIdentityStore(
      Directory('${temporary.path}/echt'),
    ).loadOrCreate();
    fremde = await ServerIdentityStore(
      Directory('${temporary.path}/fremd'),
    ).loadOrCreate();
    socket = await serve(identity);
    fremderSocket = await serve(fremde);
  });

  tearDown(() async {
    await socket.close(force: true);
    await fremderSocket.close(force: true);
    await temporary.delete(recursive: true);
  });

  PeerConnection peerAt(int port, {String? fingerprint}) => PeerConnection(
    serverId: identity.serverId,
    name: 'Mac',
    // Die zuletzt bekannte Adresse — der Port stimmt, der Rechner antwortet
    // dort aber nicht mehr.
    baseUrl: 'https://127.0.0.1:$port',
    token: 'geheim',
    certificateFingerprint: fingerprint ?? identity.certificateFingerprint,
  );

  /// Sucht auf Loopback statt im echten Netz.
  PeerAddressDiscovery discoveryAt(int port) => PeerAddressDiscovery(
    candidates: (_) async => [(host: '127.0.0.1', port: port)],
    probeTimeout: const Duration(seconds: 2),
  );

  test('findet denselben Server unter einer neuen Adresse', () async {
    // Gesucht wird auf dem Port, den die Kopplung kennt — hier zeigt sie auf
    // den laufenden Server, nur unter einem Host, der erst geprüft werden
    // muss.
    final found = await discoveryAt(socket.port).locate(peerAt(socket.port));
    expect(found, 'https://127.0.0.1:${socket.port}');
  });

  test(
    'ein fremder Rechner mit derselben Kennung wird nicht angenommen',
    () async {
      // Der Ausweis ist der Anker. Ein anderer Rechner kann die Kennung
      // behaupten, aber nicht den privaten Schlüssel vorweisen.
      final peer = PeerConnection(
        serverId: fremde.serverId,
        name: 'Angeblich',
        baseUrl: 'https://127.0.0.1:${fremderSocket.port}',
        token: 'geheim',
        // Gepinnt ist der *echte* Server, unterwegs antwortet der fremde.
        certificateFingerprint: identity.certificateFingerprint,
      );
      final found = await PeerAddressDiscovery(
        candidates: (_) async => [
          (host: '127.0.0.1', port: fremderSocket.port),
        ],
        probeTimeout: const Duration(seconds: 2),
      ).locate(peer);
      expect(found, isNull);
    },
  );

  test('ohne gepinntes Zertifikat wird gar nicht gesucht', () async {
    // Eine Adresse allein beweist nichts. Einen ungepinnten Server im Netz zu
    // suchen hieße, jedem zu glauben, der schnell genug „ich bin es" ruft.
    final found = await discoveryAt(
      socket.port,
    ).locate(peerAt(socket.port, fingerprint: ''));
    expect(found, isNull);
  });

  test('ein Server ohne Katalog ist trotzdem dieser Server', () async {
    // /health antwortet mit 503, wenn keine Bibliothek mehr antwortet. Genau
    // den will man wiederfinden — sonst sucht das Telefon einen Server, der
    // dasteht und nur gerade nichts auszuliefern hat.
    await socket.close(force: true);
    socket = await serve(identity, status: 503);
    final found = await discoveryAt(socket.port).locate(peerAt(socket.port));
    expect(found, 'https://127.0.0.1:${socket.port}');
  });

  test('eine unverschlüsselte Adresse wird nicht gesucht', () async {
    final peer = PeerConnection(
      serverId: identity.serverId,
      name: 'Test',
      baseUrl: 'http://127.0.0.1:${socket.port}',
      token: 'geheim',
      certificateFingerprint: identity.certificateFingerprint,
    );
    expect(await discoveryAt(socket.port).locate(peer), isNull);
  });
  test('ohne ausdrücklichen Wunsch wird das Netz nicht abgeklappert', () async {
    // Zweihundertvierundfünfzig Verbindungsversuche sind im Netz nicht zu
    // übersehen und von einem Portscan nicht zu unterscheiden. Das gehört
    // nicht in einen Abgleich, der alle zwanzig Sekunden läuft.
    //
    // Geprüft wird über die Zeit: findet die Ankündigung nichts, ist sofort
    // Schluss. Ein Durchlauf durch das Teilnetz bräuchte ein Vielfaches
    // davon, selbst wenn jede Adresse sofort abweist.
    final peer = peerAt(socket.port);
    final gestartet = DateTime.now();
    final found = await PeerAddressDiscovery(
      candidates: (_) async => const [],
      probeTimeout: const Duration(seconds: 2),
    ).locate(peer);
    final gedauert = DateTime.now().difference(gestartet);

    expect(found, isNull);
    expect(
      gedauert,
      lessThan(const Duration(seconds: 2)),
      reason: 'es wurde nichts weiter versucht',
    );
  });

  // Der ausdrücklich angestoßene Durchlauf durch das Teilnetz wird hier
  // bewusst *nicht* geprüft: ein solcher Test klappert das Netz des
  // CI-Rechners ab. Genau das Verhalten, das im Betrieb nur auf Wunsch
  // stattfinden soll, gehört nicht in einen Lauf, der bei jedem Push startet.
}
