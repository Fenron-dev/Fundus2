import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fundus_client/fundus_client.dart';

import 'peer_connection.dart';
import 'server_host.dart';

/// Findet einen gekoppelten Server wieder, der die Adresse gewechselt hat.
///
/// Eine Kopplung merkt sich eine feste Adresse. Im Heimnetz vergibt der Router
/// die aber per DHCP, und nach einem Neustart hat derselbe Rechner eine
/// andere: die Kopplung gilt weiter, nur klopft das Telefon an die falsche
/// Tür. Bisher endete das in „nicht erreichbar", bis jemand von Hand neu
/// gekoppelt hat — wobei die Offline-Kopien verloren gingen.
///
/// **Der Anker ist das Zertifikat, nicht die Kennung.** Der Server-Ausweis
/// aus dem Kopplungscode wird beim Suchen genauso gepinnt wie beim Benutzen.
/// Ein fremder Rechner, der sich als derselbe Server ausgibt, scheitert damit
/// schon am Handshake — er hat den privaten Schlüssel nicht. Die Server-Kennung
/// wird zusätzlich verglichen, ist aber nur eine Plausibilitätsprüfung.
///
/// Ohne gepinntes Zertifikat wird **nicht** gesucht. Eine Adresse allein
/// beweist nichts, und einen unverschlüsselten Testserver im Netz zu suchen
/// hieße, jedem zu glauben, der schnell genug „ich bin es" ruft.
final class PeerAddressDiscovery {
  const PeerAddressDiscovery({
    this.probeTimeout = const Duration(milliseconds: 600),
    this.parallel = 32,
    this.candidateHosts,
    this.ports,
  });

  /// Wie lange ein einzelner Rechner Zeit bekommt.
  ///
  /// Kurz, weil die allermeisten Adressen im Netz gar nichts sind: dort
  /// entscheidet nicht die Antwort, sondern wie schnell das Schweigen vorbei
  /// ist.
  final Duration probeTimeout;

  /// Wie viele Adressen gleichzeitig gefragt werden.
  final int parallel;

  /// Für Tests: die Liste der Adressen, statt sie aus den Netzwerkkarten
  /// dieses Geräts abzuleiten.
  final Future<List<String>> Function()? candidateHosts;

  /// Welche Ports gefragt werden. `null` heißt: der zuletzt bekannte, dann
  /// der, den ein Fundus-Server bevorzugt.
  final List<int>? ports;

  /// Die neue Adresse dieses Servers, oder `null`.
  Future<String?> locate(PeerConnection peer) async {
    final fingerprint = peer.certificateFingerprint.trim();
    if (fingerprint.isEmpty) return null;
    final known = Uri.tryParse(peer.baseUrl);
    if (known == null || known.scheme != 'https') return null;

    final hosts = await (candidateHosts?.call() ?? _localSubnetHosts(known));
    if (hosts.isEmpty) return null;

    // Der zuletzt bekannte Port zuerst: meistens hat sich nur die Adresse
    // geändert. Danach der Port, den ein Fundus-Server bevorzugt — wer beim
    // letzten Mal ausweichen musste, weil er belegt war, steht beim nächsten
    // Start wieder dort.
    final knownPort = known.hasPort
        ? known.port
        : ServerHostController.preferredPort;
    final wanted =
        ports ??
        [
          knownPort,
          if (knownPort != ServerHostController.preferredPort)
            ServerHostController.preferredPort,
        ];

    for (final port in wanted) {
      for (var index = 0; index < hosts.length; index += parallel) {
        final batch = hosts.skip(index).take(parallel);
        final found = await Future.wait([
          for (final host in batch) _ask(host, port, peer),
        ]);
        final hit = found.whereType<String>().firstOrNull;
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Fragt eine Adresse, ob sie dieser Server ist.
  Future<String?> _ask(String host, int port, PeerConnection peer) async {
    final address = host.contains(':') ? '[$host]' : host;
    final base = 'https://$address:$port';
    final client = pinnedHttpClient(peer.certificateFingerprint);
    try {
      final response = await client
          .get(Uri.parse('$base/health'))
          .timeout(probeTimeout);
      // 503 zählt: ein Server, dessen Katalog gerade nicht antwortet, ist
      // trotzdem dieser Server — und genau den will man wiederfinden.
      if (response.statusCode != 200 &&
          response.statusCode != HttpStatus.serviceUnavailable) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      return '${decoded['server_id']}' == peer.serverId ? base : null;
    } on Object {
      // Schweigen, ein fremdes Zertifikat, irgendetwas anderes an dieser
      // Adresse: alles dasselbe Ergebnis, nämlich „nicht dieser Server".
      return null;
    } finally {
      client.close();
    }
  }

  /// Die Adressen im selben Netz wie dieses Gerät.
  ///
  /// Nur IPv4 und nur ein /24: das ist das Heimnetz, um das es geht. Ein
  /// größeres Netz abzuklappern dauerte länger, als jemand vor einem
  /// Telefon zu warten bereit ist, und im Heimnetz gibt es es nicht.
  ///
  /// Das zuletzt bekannte Netz kommt zuerst — meistens hat sich nur die
  /// letzte Zahl geändert, und dann ist die Suche nach einer Sekunde vorbei.
  static Future<List<String>> _localSubnetHosts(Uri known) async {
    final prefixes = <String>[];
    void addPrefix(String address) {
      final parts = address.split('.');
      if (parts.length != 4) return;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      if (!prefixes.contains(prefix)) prefixes.add(prefix);
    }

    addPrefix(known.host);
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          addPrefix(address.address);
        }
      }
    } on Object {
      // Ohne Auskunft über die Netzwerkkarten bleibt das zuletzt bekannte
      // Netz — besser als gar nicht zu suchen.
    }

    return [
      for (final prefix in prefixes)
        for (var last = 1; last <= 254; last++)
          if ('$prefix.$last' != known.host) '$prefix.$last',
    ];
  }
}
