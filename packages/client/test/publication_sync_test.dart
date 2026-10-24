import 'dart:convert';
import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import '../../core/test/epub_package_test.dart' show epubFixture;

final class OversizedManifestClient extends http.BaseClient {
  var delivered = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        (() async* {
          for (var i = 0; i < 20; i++) {
            delivered++;
            yield List.filled(1024 * 1024, 65);
          }
        })(),
        200,
        headers: {'content-type': 'application/json'},
      );
}

void main() {
  test(
    'manifest response is stopped before buffering an unbounded body',
    () async {
      final transport = OversizedManifestClient();
      final client = FundusRemoteClient(
        baseUri: Uri.parse('https://localhost'),
        token: 'test',
        httpClient: transport,
      );
      addTearDown(client.close);
      await expectLater(
        client.publicationManifest('library', 'file'),
        throwsA(
          isA<FundusRemoteException>().having(
            (error) => error.statusCode,
            'status',
            413,
          ),
        ),
      );
      expect(transport.delivered, lessThanOrEqualTo(5));
    },
  );

  group('real server / client chapter hydration', () {
    late Directory root;
    late File book;
    late FundusLibrary host;
    late FundusLibrary phone;
    late HttpServer server;
    late FundusRemoteClient client;
    late FundusLibraryRegistry registry;
    late String workId;
    var failing = 0;
    var oldCapabilities = false;
    final requested = <String>[];

    FundusCatalogueMirror mirror() => FundusCatalogueMirror(
      library: phone,
      client: client,
      libraryId: host.manifest.libraryId,
      sourceId: 'peer-test',
    );

    setUp(() async {
      requested.clear();
      failing = 0;
      oldCapabilities = false;
      root = await Directory.systemTemp.createTemp('fundus-publication-sync-');
      book = File('${root.path}/host/Webnovels/Series/Novel.epub');
      await book.parent.create(recursive: true);
      await book.writeAsBytes(epubFixture(includeSecond: false));
      host = await FundusLibrary.create(Directory('${root.path}/host'));
      await host.index().drain<void>();
      workId = host.listWorks().single.id;
      phone = await FundusLibrary.create(Directory('${root.path}/phone'));
      registry = FundusLibraryRegistry()..register(host, name: 'Host');
      final handler = FundusServerHandler(
        token: 'test',
        serverId: 'host',
        registry: registry,
      ).handler;
      server = await shelf_io.serve(
        (request) {
          requested.add(request.url.path);
          if (oldCapabilities && request.url.path == 'v1/capabilities') {
            return shelf.Response.ok(
              jsonEncode({'capabilities': []}),
              headers: {'content-type': 'application/json'},
            );
          }
          if (failing != 0 &&
              request.url.path.endsWith('/publication-manifest')) {
            return shelf.Response(
              failing,
              body: jsonEncode({'error': 'temporary'}),
              headers: {'content-type': 'application/json'},
            );
          }
          return handler(request);
        },
        InternetAddress.loopbackIPv4,
        0,
      );
      client = FundusRemoteClient(
        baseUri: Uri.parse('http://localhost:${server.port}'),
        token: 'test',
      );
      phone.registerPeerSource(
        sourceId: 'peer-test',
        displayName: 'Host',
        libraryId: host.manifest.libraryId,
        baseUrl: 'http://localhost:${server.port}',
      );
      await mirror().run();
    });
    tearDown(() async {
      client.close();
      await server.close(force: true);
      registry.unregister(host.manifest.libraryId);
      await host.shutdown();
      await phone.shutdown();
      await root.delete(recursive: true);
    });

    Future<void> subscribe() async {
      await hydratePublicationManifests(
        library: phone,
        client: client,
        sourceId: 'peer-test',
        libraryId: host.manifest.libraryId,
        workIds: {workId},
      );
      await phone.setContentSubscription(workId, true);
    }

    test(
      'new embedded chapters cross the delta with metadata only and no repeated hydration',
      () async {
        await subscribe();
        expect(phone.contentUpdates, isEmpty);
        expect(
          requested.where((path) => path.endsWith('/publication-manifest')),
          hasLength(1),
        );
        await book.writeAsBytes(epubFixture());
        await host.index().drain<void>();
        await mirror().run();
        final event = phone.contentUpdates.single;
        expect(event.kind, ContentUpdateKind.added);
        expect(event.file.chapterId, isNotNull);
        expect(event.file.title, contains('Unterkapitel Zwei'));
        expect(requested.where((path) => path.endsWith('/content')), isEmpty);
        final requestsBefore = requested
            .where((path) => path.endsWith('/publication-manifest'))
            .length;
        await mirror().run();
        expect(
          requested.where((path) => path.endsWith('/publication-manifest')),
          hasLength(requestsBefore),
        );
        expect(phone.contentUpdates, hasLength(1));
      },
    );

    test(
      '503 defers this baseline without failing the catalogue, then retries unchanged index',
      () async {
        await subscribe();
        await book.writeAsBytes(epubFixture());
        await host.index().drain<void>();
        failing = 503;
        final result = await mirror().run();
        expect(result.written, 1);
        expect(phone.listWorks(), hasLength(1));
        expect(phone.contentUpdates, isEmpty);
        failing = 0;
        await mirror().run();
        expect(phone.contentUpdates.single.kind, ContentUpdateKind.added);
        expect(phone.contentUpdates.single.file.chapterId, isNotNull);
      },
    );

    test(
      'revoked manifest access is never masked as an offline/transient fallback',
      () async {
        await subscribe();
        await book.writeAsBytes(epubFixture());
        await host.index().drain<void>();
        failing = 403;
        await expectLater(
          mirror().run(),
          throwsA(
            isA<FundusRemoteException>().having(
              (error) => error.statusCode,
              'status',
              403,
            ),
          ),
        );
        expect(phone.contentUpdates, isEmpty);
      },
    );

    test(
      'older peers keep file-level notices and do not get unsupported chapter requests',
      () async {
        oldCapabilities = true;
        await subscribe();
        expect(
          requested.where((path) => path.endsWith('/publication-manifest')),
          isEmpty,
        );
        await book.writeAsBytes(epubFixture());
        await host.index().drain<void>();
        await mirror().run();
        expect(phone.contentUpdates.single.kind, ContentUpdateKind.changed);
        expect(phone.contentUpdates.single.file.chapterId, isNull);
        expect(
          requested.where((path) => path.endsWith('/publication-manifest')),
          isEmpty,
        );
      },
    );
  });
}
