import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// The sync, tried against a real Fundus over a real socket.
///
/// Two devices with the same vault is the case this exists for: the work ids
/// live in the vault's own sidecars, so a copy of a library carries the same
/// ids and the two sides can talk about the same works.
void main() {
  late Directory temporary;
  late FundusLibrary mine;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late FundusRemoteClient client;
  late String workId;
  late String fileId;

  Uri baseUri() => Uri.parse('http://localhost:${socket.port}');

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-sync-');

    final source = Directory('${temporary.path}/meine');
    mine = await _library(source);
    workId = mine.listWorks().single.id;
    fileId = mine.playbackTracks(workId).single.fileId;

    // Dieselbe Bibliothek auf einem zweiten Gerät.
    final copy = Directory('${temporary.path}/ihre');
    await _copyDirectory(source, copy);
    theirs = await FundusLibrary.open(copy);

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    final handler = FundusServerHandler(
      token: 'geheim',
      serverId: 'server-test',
      serverName: 'Der andere Rechner',
      registry: registry,
    );
    socket = await shelf_io.serve(handler.handler, 'localhost', 0);
    client = FundusRemoteClient(baseUri: baseUri(), token: 'geheim');
  });

  tearDown(() async {
    client.close();
    await socket.close(force: true);
    registry.close();
    mine.close();
    await temporary.delete(recursive: true);
  });

  FundusSync syncer() => FundusSync(
    library: mine,
    client: client,
    libraryId: theirs.manifest.libraryId,
    deviceId: 'mein-geraet',
  );

  test('die Gegenstelle nennt ihre Bibliotheken und Werke', () async {
    final libraries = await client.libraries();
    expect(libraries, hasLength(1));
    expect(libraries.single.name, 'Hörbücher');

    final works = await client.works(libraries.single.id);
    expect(works, hasLength(1));
    expect(works.single.id, workId);
  });

  test('mein Stand geht hinüber, wenn drüben keiner ist', () async {
    mine.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mein-geraet',
    );

    final report = await syncer().run();

    expect(report.pushedProgress, 1);
    expect(report.pulledProgress, 0);
    final over = theirs.loadProgress(workId);
    expect(over, isNotNull);
    expect(over!.position.numericValue, closeTo(12 * 60, 0.001));
  });

  test('der fremde Stand kommt herüber, wenn ich keinen habe', () async {
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 30),
      deviceId: 'anderes-geraet',
    );

    final report = await syncer().run();

    expect(report.pulledProgress, 1);
    expect(
      mine.loadProgress(workId)!.position.numericValue,
      closeTo(30 * 60, 0.001),
    );
  });

  test('der neuere Stand gewinnt, nicht der weitere', () async {
    // Drüben weiter, aber älter.
    theirs.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 40),
      deviceId: 'anderes-geraet',
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    mine.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mein-geraet',
    );

    final report = await syncer().run();

    expect(report.pushedProgress, 1);
    expect(
      theirs.loadProgress(workId)!.position.numericValue,
      closeTo(12 * 60, 0.001),
    );
    // Zurückgespult heißt zurückgespult; wer zuletzt gelesen hat, bestimmt.
    expect(
      mine.loadProgress(workId)!.position.numericValue,
      closeTo(12 * 60, 0.001),
    );
  });

  test('ein zweiter Durchlauf ändert nichts mehr', () async {
    mine.saveProgress(
      workId: workId,
      fileId: fileId,
      position: const Duration(minutes: 12),
      deviceId: 'mein-geraet',
    );

    await syncer().run();
    final second = await syncer().run();

    expect(second.changedAnything, isFalse);
    expect(second.summary, contains('Nichts zu tun'));
  });

  test('Lesezeichen zählen zusammen, sie überschreiben sich nicht', () async {
    await mine.addMediaBookmark(
      workId: workId,
      fileId: fileId,
      position: const MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: 120,
      ),
      label: 'Meins',
    );
    await theirs.addMediaBookmark(
      workId: workId,
      fileId: fileId,
      position: const MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: 300,
      ),
      label: 'Ihres',
    );

    final report = await syncer().run();

    expect(report.pulledMarks, 1);
    expect(report.pushedMarks, 1);
    expect(mine.loadAnnotations(workId).bookmarks, hasLength(2));
    expect(theirs.loadAnnotations(workId).bookmarks, hasLength(2));

    // Und beim nächsten Mal entstehen keine Duplikate.
    final second = await syncer().run();
    expect(second.pulledMarks, 0);
    expect(second.pushedMarks, 0);
    expect(mine.loadAnnotations(workId).bookmarks, hasLength(2));
  });

  test('Markierungen wandern mit ihrem Wortlaut', () async {
    await mine.addTextHighlight(
      workId: workId,
      fileId: fileId,
      position: const MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 40,
        elementId: 'paragraph-7',
        scrollOffset: .25,
      ),
      quote: 'Die Wendung',
    );

    await syncer().run();

    final over = theirs.loadAnnotations(workId).highlights;
    expect(over, hasLength(1));
    expect(over.single.quote, 'Die Wendung');
    expect(over.single.mediaPosition.elementId, 'paragraph-7');
  });

  test('ein Werk, das es drüben nicht gibt, ist kein Fehler', () async {
    final report = await syncer().run(workIds: ['gibt-es-nicht']);

    expect(report.skipped, 1);
    expect(report.failures, isEmpty);
  });

  test('ein falsches Token wird als solches gemeldet', () async {
    final wrong = FundusRemoteClient(baseUri: baseUri(), token: 'falsch');
    addTearDown(wrong.close);

    await expectLater(
      wrong.libraries(),
      throwsA(
        isA<FundusRemoteException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.isTransient, 'isTransient', isFalse),
      ),
    );
  });

  group('Kopplung', () {
    test('Code und PIN ergeben ein Token, das dann auch gilt', () async {
      final authority = FundusPairingAuthority();
      final session = authority.begin();
      final paired = FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        serverName: 'Der andere Rechner',
        registry: registry,
        pairingAuthority: authority,
      );
      final pairedSocket = await shelf_io.serve(paired.handler, 'localhost', 0);
      addTearDown(() => pairedSocket.close(force: true));

      final code = FundusPairingCode(
        baseUri: Uri.parse('http://localhost:${pairedSocket.port}'),
        serverId: 'server-test',
        certificateFingerprint: '0' * 64,
        nonce: session.nonce,
        expiresAt: session.expiresAt,
        serverName: 'Der andere Rechner',
      );

      final result = await FundusRemoteClient.claim(
        code: code,
        pin: session.pin,
        deviceId: 'mein-geraet',
        deviceName: 'MacBook',
      );

      expect(result.token, isNotEmpty);
      expect(result.serverName, 'Der andere Rechner');

      final paired2 = FundusRemoteClient(
        baseUri: code.baseUri,
        token: result.token,
      );
      addTearDown(paired2.close);
      expect(await paired2.libraries(), hasLength(1));
    });

    test('eine falsche PIN wird abgewiesen', () async {
      final authority = FundusPairingAuthority();
      final session = authority.begin();
      final paired = FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        registry: registry,
        pairingAuthority: authority,
      );
      final pairedSocket = await shelf_io.serve(paired.handler, 'localhost', 0);
      addTearDown(() => pairedSocket.close(force: true));

      await expectLater(
        FundusRemoteClient.claim(
          code: FundusPairingCode(
            baseUri: Uri.parse('http://localhost:${pairedSocket.port}'),
            serverId: 'server-test',
            certificateFingerprint: '0' * 64,
            nonce: session.nonce,
            expiresAt: session.expiresAt,
          ),
          pin: '000000',
          deviceId: 'mein-geraet',
          deviceName: 'MacBook',
        ),
        throwsA(
          isA<FundusRemoteException>().having(
            (error) => error.message,
            'message',
            contains('stimmen nicht'),
          ),
        ),
      );
    });

    test('ein abgelaufener Code wird gar nicht erst gesendet', () async {
      await expectLater(
        FundusRemoteClient.claim(
          code: FundusPairingCode(
            baseUri: Uri.parse('http://localhost:1'),
            serverId: 'x',
            certificateFingerprint: '0' * 64,
            nonce: 'n',
            expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          pin: '123456',
          deviceId: 'a',
          deviceName: 'b',
        ),
        throwsA(
          isA<FundusRemoteException>().having(
            (error) => error.message,
            'message',
            contains('abgelaufen'),
          ),
        ),
      );
    });
  });

  group('Der Kopplungscode', () {
    test('ein vollständiger Code wird gelesen', () {
      final code = FundusPairingCode(
        baseUri: Uri.parse('https://mac.local:7443'),
        serverId: 'server-1',
        certificateFingerprint: 'a' * 64,
        nonce: 'abc',
        expiresAt: DateTime.utc(2030),
        serverName: 'MacBook',
      );

      final parsed = FundusPairingCode.parse(code.encode());

      expect(parsed.baseUri, code.baseUri);
      expect(parsed.nonce, 'abc');
      expect(parsed.serverName, 'MacBook');
    });

    test('ein Code mit Zugangsdaten in der Adresse wird abgelehnt', () {
      expect(
        () => FundusPairingCode.parse(
          '{"type":"fundus_pairing","version":1,'
          '"base_url":"https://wer:auch@immer.example",'
          '"certificate_sha256":"${'a' * 64}",'
          '"nonce":"n","expires_at":"2030-01-01T00:00:00Z"}',
        ),
        throwsFormatException,
      );
    });

    test('unverschlüsseltes HTTP wird nur für Loopback akzeptiert', () {
      expect(
        () => FundusPairingCode.parse(
          '{"type":"fundus_pairing","version":1,'
          '"base_url":"http://192.168.1.20:47891",'
          '"certificate_sha256":"",'
          '"nonce":"n","expires_at":"2030-01-01T00:00:00Z"}',
        ),
        throwsFormatException,
      );
    });

    test('etwas anderes als ein Kopplungscode wird abgelehnt', () {
      expect(() => FundusPairingCode.parse('hallo'), throwsFormatException);
      expect(
        () => FundusPairingCode.parse('{"type":"anderes"}'),
        throwsFormatException,
      );
    });
  });
}

Future<FundusLibrary> _library(Directory root) async {
  final work = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
  await work.create(recursive: true);
  await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
  final library = await FundusLibrary.create(root);
  await for (final _ in library.index()) {}
  return library;
}

Future<void> _copyDirectory(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    if (entity is Directory) {
      await Directory('${to.path}/$relative').create(recursive: true);
    } else if (entity is File) {
      final target = File('${to.path}/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    }
  }
}
