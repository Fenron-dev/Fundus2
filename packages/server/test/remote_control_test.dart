import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

final class _FakeRemote implements FundusRemoteControl {
  FundusRemoteState current = FundusRemoteState.idle;
  final played = <String>[];
  final commands = <(FundusRemoteAction, Duration?)>[];

  @override
  FundusRemoteState state() => current;

  @override
  Future<bool> playWork(String libraryId, String workId) async {
    played.add(workId);
    return true;
  }

  @override
  Future<void> command(FundusRemoteAction action, {Duration? position}) async =>
      commands.add((action, position));
}

/// A phone may steer the player of the machine it is paired with — once it
/// has been allowed to, and never past the protection rules.
void main() {
  late Directory root;
  late FundusLibrary library;
  late FundusLibraryRegistry registry;
  late FundusPairingAuthority authority;
  late _FakeRemote remote;
  late FundusServerHandler server;
  late LibraryWorkSummary open;
  late LibraryWorkSummary protected;
  const token = 'phone-token';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-remote-');
    for (final title in ['Offen', 'Geschützt']) {
      final work = Directory('${root.path}/Audiobooks/Autor/Serie/01 - $title')
        ..createSync(recursive: true);
      File('${work.path}/01.mp3').writeAsBytesSync([1, 2, 3]);
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    open = library.listWorks().firstWhere((work) => work.title == 'Offen');
    final secret = library.listWorks().firstWhere(
      (work) => work.title == 'Geschützt',
    );
    await library.updateWorkMetadata(
      workId: secret.id,
      title: secret.title,
      authors: secret.authors,
      subtitle: secret.subtitle,
      series: secret.series,
      seriesSequence: secret.seriesSequence,
      narrators: secret.narrators,
      language: secret.language,
      description: secret.description,
      publisher: secret.publisher,
      publishedYear: secret.publishedYear,
      contentSensitivity: 'adult_explicit',
    );
    protected = library.listWorks().firstWhere((work) => work.id == secret.id);
    registry = FundusLibraryRegistry()..register(library, name: 'Hörbücher');
    authority = FundusPairingAuthority(
      devices: [
        FundusPairedDevice(
          id: 'phone',
          name: 'Telefon',
          tokenHash: FundusPairingAuthority.tokenDigest(token),
          pairedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    remote = _FakeRemote();
    server = FundusServerHandler(
      token: 'secret',
      serverId: 'mac',
      registry: registry,
      pairingAuthority: authority,
      remoteControl: remote,
    );
  });

  tearDown(() async {
    registry.close();
    await root.delete(recursive: true);
  });

  Future<Response> send(String method, String path, [Object? body]) async =>
      server.handler(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {
            'authorization': 'Bearer $token',
            if (body != null) 'content-type': 'application/json',
          },
          body: body == null ? null : jsonEncode(body),
        ),
      );

  test('without the grant the player cannot be reached', () async {
    expect((await send('GET', '/v1/remote/state')).statusCode, 403);
    final command = await send('POST', '/v1/remote/commands', {
      'action': 'pause',
    });
    expect(command.statusCode, 403);
    expect(remote.commands, isEmpty);
  });

  test('with the grant it plays and is steered', () async {
    await authority.setRemoteControlAllowed('phone', true);
    final libraryId = library.manifest.libraryId;
    final started = await send('POST', '/v1/remote/commands', {
      'action': 'play_work',
      'library_id': libraryId,
      'work_id': open.id,
    });
    expect(started.statusCode, 200);
    expect(remote.played, [open.id]);

    await send('POST', '/v1/remote/commands', {
      'action': 'seek',
      'position_seconds': 90,
    });
    expect(remote.commands.single, (
      FundusRemoteAction.seek,
      const Duration(seconds: 90),
    ));
    final bad = await send('POST', '/v1/remote/commands', {'action': 'rm'});
    expect(bad.statusCode, 400);
  });

  test('a protected work stays hidden and cannot be started', () async {
    await authority.setRemoteControlAllowed('phone', true);
    final libraryId = library.manifest.libraryId;
    final refused = await send('POST', '/v1/remote/commands', {
      'action': 'play_work',
      'library_id': libraryId,
      'work_id': protected.id,
    });
    expect(refused.statusCode, 404);
    expect(remote.played, isEmpty);

    remote.current = FundusRemoteState(
      libraryId: libraryId,
      workId: protected.id,
      title: protected.title,
      playing: true,
    );
    final state =
        jsonDecode(await (await send('GET', '/v1/remote/state')).readAsString())
            as Map;
    expect(state['private'], isTrue);
    expect(state.containsKey('title'), isFalse);
    expect(jsonEncode(state), isNot(contains('Geschützt')));
  });
}
