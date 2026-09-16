import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../app/fundus_log.dart';

/// Der Diensttyp, unter dem ein Fundus-Server sich im lokalen Netz meldet.
///
/// Muss auf beiden Seiten derselbe sein und steht deshalb hier, nicht zweimal.
const fundusServiceType = '_fundus._tcp';

/// Sagt dem Netz, dass hier ein Fundus-Server steht.
///
/// Ohne das müsste die Gegenseite raten: eine Adresse nach der anderen
/// durchprobieren, bis eine antwortet. Das sind zweihundertvierundfünfzig
/// Verbindungsversuche für eine Auskunft, die der Server genauso gut von sich
/// aus geben kann — und es sieht im Netz aus wie ein Portscan, weil es einer
/// ist.
///
/// Angekündigt wird nur, *dass* und *wo*. Wer hereindarf, entscheidet
/// weiterhin die Kopplung, und womit man sich ausweist, das Zertifikat. Eine
/// Ankündigung ist eine Einladung zum Anklopfen, kein Schlüssel.
final class PeerAnnouncement {
  PeerAnnouncement();

  BonsoirBroadcast? _broadcast;
  String? _announced;

  /// Ob gerade etwas angekündigt wird.
  bool get isAnnouncing => _broadcast != null;

  /// Meldet diesen Server an, oder meldet ihn unter neuen Angaben erneut an.
  Future<void> announce({
    required String serverId,
    required String serverName,
    required int port,
  }) async {
    final signature = '$serverId|$serverName|$port';
    if (_announced == signature && _broadcast != null) return;
    await withdraw();
    try {
      final broadcast = BonsoirBroadcast(
        service: BonsoirService(
          // Der Gerätename ist das, was ein Mensch in einer Liste wiedererkennt.
          name: serverName.trim().isEmpty ? 'Fundus' : serverName.trim(),
          type: fundusServiceType,
          port: port,
          // Die Kennung entscheidet, welcher Server das ist — der Name kann
          // sich ändern und zweimal vorkommen.
          attributes: {'server_id': serverId},
        ),
      );
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
      _announced = signature;
      FundusLog.instance.info('peer.announce', {
        'action': 'started',
        'port': port,
      });
    } on Object catch (error) {
      // Ein Netz ohne Multicast, eine verweigerte Berechtigung, eine Plattform
      // ohne Unterstützung: alles kein Grund, den Server nicht zu betreiben.
      // Wer die Adresse kennt, kommt weiterhin herein.
      _broadcast = null;
      _announced = null;
      FundusLog.instance.warn('peer.announce', {
        'action': 'unavailable',
        'error': '$error',
      });
    }
  }

  Future<void> withdraw() async {
    final broadcast = _broadcast;
    _broadcast = null;
    _announced = null;
    if (broadcast == null) return;
    try {
      await broadcast.stop();
    } on Object {
      // Beim Aufräumen ist ein Fehlschlag nichts, was jemanden noch
      // interessieren würde.
    }
  }
}
