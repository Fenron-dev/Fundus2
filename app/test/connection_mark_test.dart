import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/peer_connection.dart';
import 'package:fundus/data/peer_library.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Whether the other machine is answering — the same fact from both ends.
///
/// The phone asking „does the Mac answer" and the Mac asking „is the phone
/// there" are one thing seen twice, and both are kept alive by the same
/// heartbeat: the client asks, and the asking is what marks it present over
/// there.
void main() {
  late Directory temporary;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late FundusPairingAuthority authority;
  late HttpServer socket;
  late LibraryController library;
  late AppSettings settings;
  late PeerLibraries peers;
  late String token;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-mark-');
    final source = Directory('${temporary.path}/mac');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    theirs = await FundusLibrary.create(source);
    await for (final _ in theirs.index()) {}

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    authority = FundusPairingAuthority();
    final session = authority.begin();
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'unbenutzt',
        serverId: 'server-test',
        serverName: 'Mac',
        registry: registry,
        pairingAuthority: authority,
      ).handler,
      'localhost',
      0,
    );

    // Echt koppeln, damit die Gegenstelle das Gerät auch kennt.
    final claimed = await FundusRemoteClient.claim(
      code: FundusPairingCode(
        baseUri: Uri.parse('http://localhost:${socket.port}'),
        serverId: 'server-test',
        certificateFingerprint: '0' * 64,
        nonce: session.nonce,
        expiresAt: session.expiresAt,
      ),
      pin: session.pin,
      deviceId: 'handy',
      deviceName: 'Fenrons Handy',
    );
    token = claimed.token;

    library = LibraryController();
    settings = AppSettings.inMemory();
    peers = PeerLibraries(
      settings: settings,
      library: library,
      storageRoot: () async => Directory('${temporary.path}/speicher'),
    );
  });

  tearDown(() async {
    peers.dispose();
    library.dispose();
    await socket.close(force: true);
    registry.close();
    await temporary.delete(recursive: true);
  });

  PeerConnection peer() => PeerConnection(
    serverId: 'server-test',
    name: 'Mac',
    baseUrl: 'http://localhost:${socket.port}',
    token: token,
  );

  test('ohne geöffnete Gegenstelle ist die Marke aus', () {
    expect(peers.connection, FundusConnectionState.idle);
  });

  test('nach dem Öffnen leuchtet sie auf beiden Seiten', () async {
    expect(await peers.connect(peer()), isTrue, reason: peers.failure ?? '');

    // Diese Seite: die Gegenstelle hat eben geantwortet.
    expect(peers.connection, FundusConnectionState.connected);

    // Und drüben ist das Gerät als anwesend vermerkt — durch dieselben
    // Anfragen, mit denen es den Katalog geholt hat.
    final device = authority.devices.single;
    expect(device.name, 'Fenrons Handy');
    expect(device.lastSeenAt, isNotNull);
    expect(
      DateTime.now().toUtc().difference(device.lastSeenAt!),
      lessThan(const Duration(seconds: 10)),
    );
  });

  test(
    'ein entzogener Zugang wird als Abweisung gezeigt, nicht als Stille',
    () async {
      await peers.connect(peer());
      await authority.revoke(authority.devices.single.id);

      await peers.refresh();

      expect(peers.connection, FundusConnectionState.refused);
      expect(peers.failure, isNotNull);
    },
  );

  test('der Herzschlag hält die Marke am Leben', () async {
    await peers.connect(peer());
    final client = FundusRemoteClient(
      baseUri: Uri.parse('http://localhost:${socket.port}'),
      token: token,
    );
    addTearDown(client.close);

    expect(await client.ping(), isTrue);
  });
}
