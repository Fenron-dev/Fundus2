import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:fundus_client/fundus_client.dart';

import 'peer_announcement.dart';
import 'peer_connection.dart';
import 'server_host.dart';

/// Eine Adresse, die dieser Server sein könnte.
typedef PeerCandidate = ({String host, int port});

/// Findet einen gekoppelten Server wieder, der die Adresse gewechselt hat.
///
/// Eine Kopplung merkt sich eine feste Adresse. Im Heimnetz vergibt der Router
/// die aber per DHCP, und nach einem Neustart hat derselbe Rechner eine
/// andere: die Kopplung gilt weiter, nur klopft das Telefon an die falsche
/// Tür. Bisher endete das in „nicht erreichbar", bis jemand von Hand neu
/// gekoppelt hat — wobei die Offline-Kopien verloren gingen.
///
/// **Gefragt wird das Netz, nicht jede Adresse darin.** Der Server meldet sich
/// über mDNS an (siehe [PeerAnnouncement]); hier wird zugehört. Das ist eine
/// Multicast-Frage statt zweihundertvierundfünfzig Verbindungsversuchen — und
/// es ist auch das, was hinter „den Rechnernamen verwenden" steckt: `.local`
/// aufzulösen *ist* mDNS.
///
/// **Die Ankündigung entscheidet nichts.** Sie ist unbeglaubigt; jeder im Netz
/// kann eine beliebige Kennung ausrufen. Sie liefert deshalb nur Kandidaten,
/// und welcher davon dieser Server ist, entscheidet der Ausweis aus dem
/// Kopplungscode: gepinnt wie beim Benutzen, sodass ein fremder Rechner schon
/// am Handshake scheitert — er hat den privaten Schlüssel nicht.
///
/// Ohne gepinntes Zertifikat wird **nicht** gesucht. Eine Adresse allein
/// beweist nichts, und einen unverschlüsselten Testserver im Netz zu suchen
/// hieße, jedem zu glauben, der schnell genug „ich bin es" ruft.
final class PeerAddressDiscovery {
  const PeerAddressDiscovery({
    this.probeTimeout = const Duration(seconds: 3),
    this.listenFor = const Duration(seconds: 4),
    this.candidates,
    this.sweepSubnet = false,
  });

  /// Wie lange ein einzelner Kandidat Zeit bekommt, sich auszuweisen.
  final Duration probeTimeout;

  /// Wie lange dem Netz zugehört wird.
  ///
  /// Lang genug, dass ein Gerät im Stromsparmodus antworten kann, kurz genug,
  /// dass niemand davor wartet. Wer früher gefunden wird, beendet das Warten
  /// sofort.
  final Duration listenFor;

  /// Für Tests: die Kandidaten, statt sie im Netz zu erfragen.
  final Future<List<PeerCandidate>> Function(PeerConnection peer)? candidates;

  /// Ob als letzte Möglichkeit doch das Teilnetz abgeklappert werden darf.
  ///
  /// Standardmäßig nicht. Zweihundertvierundfünfzig Verbindungsversuche sind
  /// im Netz nicht zu übersehen und von einem Portscan nicht zu unterscheiden;
  /// das gehört nicht in einen Hintergrundabgleich, der alle zwanzig Sekunden
  /// läuft. Als ausdrücklich angestoßene Suche ist es etwas anderes.
  final bool sweepSubnet;

  /// Die neue Adresse dieses Servers, oder `null`.
  Future<String?> locate(PeerConnection peer) async {
    if (peer.certificateFingerprint.trim().isEmpty) return null;
    final known = Uri.tryParse(peer.baseUrl);
    if (known == null || known.scheme != 'https') return null;

    final found = await (candidates?.call(peer) ?? _announced(peer));
    for (final candidate in found) {
      final address = await _ask(candidate, peer);
      if (address != null) return address;
    }
    if (!sweepSubnet) return null;
    return _sweep(known, peer);
  }

  /// Hört, wer sich im Netz als Fundus-Server meldet.
  Future<List<PeerCandidate>> _announced(PeerConnection peer) async {
    final found = <PeerCandidate>[];
    BonsoirDiscovery? discovery;
    final done = Completer<void>();
    try {
      discovery = BonsoirDiscovery(type: fundusServiceType);
      await discovery.initialize();
      final subscription = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            // Ein Fund nennt noch keine Adresse; die kommt erst beim Auflösen.
            unawaited(
              Future<void>.sync(
                () => discovery!.serviceResolver.resolveService(event.service),
              ).catchError((Object _) {}),
            );
          case BonsoirDiscoveryServiceResolvedEvent():
            final service = event.service;
            if (service.attributes['server_id'] != peer.serverId) return;
            for (final host in service.hostAddresses) {
              final candidate = (host: host, port: service.port);
              if (!found.contains(candidate)) found.add(candidate);
            }
            if (found.isNotEmpty && !done.isCompleted) done.complete();
          default:
            break;
        }
      });
      await discovery.start();
      await done.future.timeout(listenFor, onTimeout: () {});
      await subscription?.cancel();
    } on Object {
      // Kein Multicast, keine Berechtigung, keine Unterstützung: dann eben
      // keine Kandidaten. Die gespeicherte Adresse gilt weiter.
    } finally {
      try {
        await discovery?.stop();
      } on Object {
        // Aufräumen.
      }
    }
    return found;
  }

  /// Fragt einen Kandidaten, ob er dieser Server ist.
  Future<String?> _ask(PeerCandidate candidate, PeerConnection peer) async {
    final host = candidate.host.contains(':')
        ? '[${candidate.host}]'
        : candidate.host;
    final base = 'https://$host:${candidate.port}';
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

  /// Das Teilnetz der Reihe nach — nur auf ausdrücklichen Wunsch.
  Future<String?> _sweep(Uri known, PeerConnection peer) async {
    final knownPort = known.hasPort
        ? known.port
        : ServerHostController.preferredPort;
    final ports = [
      knownPort,
      if (knownPort != ServerHostController.preferredPort)
        ServerHostController.preferredPort,
    ];
    final hosts = await _localSubnetHosts(known);
    const parallel = 32;
    for (final port in ports) {
      for (var index = 0; index < hosts.length; index += parallel) {
        final found = await Future.wait([
          for (final host in hosts.skip(index).take(parallel))
            _ask((host: host, port: port), peer),
        ]);
        final hit = found.whereType<String>().firstOrNull;
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Die Adressen im selben Netz wie dieses Gerät.
  ///
  /// Nur IPv4 und nur ein /24: das ist das Heimnetz, um das es geht. Das
  /// zuletzt bekannte Netz kommt zuerst — meistens hat sich nur die letzte
  /// Zahl geändert.
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
      // Ohne Auskunft über die Netzwerkkarten bleibt das zuletzt bekannte Netz.
    }

    return [
      for (final prefix in prefixes)
        for (var last = 1; last <= 254; last++)
          if ('$prefix.$last' != known.host) '$prefix.$last',
    ];
  }
}
