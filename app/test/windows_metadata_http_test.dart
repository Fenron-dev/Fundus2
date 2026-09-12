import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/server_identity.dart';
import 'package:fundus/metadata/metadata_apply.dart';
import 'package:fundus/metadata/metadata_http_client.dart';
import 'package:http/http.dart' as http;

void main() {
  group('Native Windows metadata transport', () {
    late http.Client client;
    late HttpServer server;
    late Uri base;
    setUp(() async {
      client = createMetadataHttpClient();
      expect(client, isA<WindowsMetadataClient>());
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}/');
      server.listen((request) async {
        switch (request.uri.path) {
          case '/redirect':
            request.response.statusCode = 302;
            request.response.headers.set('location', '/binary');
          case '/cross-origin':
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://localhost:${server.port}/auth',
            );
          case '/auth':
            request.response.write(
              request.headers.value('authorization') ?? 'none',
            );
          case '/binary':
            request.response.add([0, 1, 127, 128, 255]);
          case '/gzip':
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(gzip.encode(utf8.encode('Grüße')));
          case '/echo':
            request.response.add(
              await request.fold<List<int>>(
                [],
                (all, bytes) => all..addAll(bytes),
              ),
            );
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });
    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test('POST, binary bytes, gzip, HTTP errors and close', () async {
      final post = await client.post(
        base.resolve('echo'),
        body: '{"title":"Manga 日本語"}',
      );
      expect(utf8.decode(post.bodyBytes), '{"title":"Manga 日本語"}');
      expect((await client.get(base.resolve('binary'))).bodyBytes, [
        0,
        1,
        127,
        128,
        255,
      ]);
      expect(
        utf8.decode((await client.get(base.resolve('gzip'))).bodyBytes),
        'Grüße',
      );
      expect((await client.get(base)).statusCode, 404);
      client.close();
      await expectLater(client.get(base), throwsA(isA<http.ClientException>()));
    });

    test(
      'redirects preserve bytes but remove cross-origin credentials',
      () async {
        expect((await client.get(base.resolve('redirect'))).bodyBytes, [
          0,
          1,
          127,
          128,
          255,
        ]);
        final response = await client.get(
          base.resolve('cross-origin'),
          headers: {'Authorization': 'secret'},
        );
        expect(response.body, 'none');
        final request = http.Request('GET', base.resolve('redirect'))
          ..followRedirects = false;
        expect((await client.send(request)).statusCode, 302);
        final limited = http.Request('GET', base.resolve('redirect'))
          ..maxRedirects = 0;
        await expectLater(
          client.send(limited),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'self-signed TLS is rejected without trusting the paired-server CA',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'fundus-winhttp-tls-',
        );
        HttpServer? secure;
        try {
          final identity = await ServerIdentityStore(temporary).loadOrCreate();
          final context = SecurityContext()
            ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
            ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
          secure = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            context,
          );
          secure.listen((request) {
            request.response.close();
          }, onError: (Object _) {});
          await expectLater(
            client.get(Uri.parse('https://127.0.0.1:${secure.port}/')),
            throwsA(
              isA<WindowsMetadataException>().having(
                (e) => e.code,
                'certificate error',
                isIn([12175, 12045]),
              ),
            ),
          );
        } finally {
          await secure?.close(force: true);
          await temporary.delete(recursive: true);
        }
      },
    );
  }, skip: !Platform.isWindows);

  test(
    'Live Windows: AniList POST, AniList cover, TMDB cover and API TLS',
    () async {
      final client = createMetadataHttpClient();
      try {
        http.Response? response;
        for (var attempt = 0; attempt < 3; attempt++) {
          response = await client.post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'query': '{ Media(id: 1) { id coverImage { large } } }',
            }),
          );
          if (response.statusCode != 429 || attempt == 2) break;
          final seconds =
              int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
          // Shared CI egress can be rate-limited. Wait rather than pretending
          // a 429 is a successful metadata download or a certificate failure.
          if (seconds > 60) break;
          await Future<void>.delayed(Duration(seconds: seconds.clamp(1, 60)));
        }
        expect(response!.statusCode, 200, reason: 'AniList HTTPS POST');
        final media =
            (jsonDecode(response.body) as Map)['data']['Media'] as Map;
        final cover = await fetchCoverBytes(
          media['coverImage']['large'] as String,
        );
        expect(
          cover,
          isNotNull,
          reason: 'AniList cover through production factory',
        );
        expect(cover!.length, greaterThan(100));
        final tmdb = await fetchCoverBytes(
          'https://image.tmdb.org/t/p/w92/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg',
        );
        expect(
          tmdb,
          isNotNull,
          reason: 'TMDB cover through production factory',
        );
        expect(tmdb!.length, greaterThan(100));
        // No private key needed: an HTTP 401 proves TLS succeeded at the API host.
        expect(
          (await client.get(
            Uri.parse('https://api.themoviedb.org/3/configuration'),
          )).statusCode,
          401,
        );
      } finally {
        client.close();
      }
    },
    skip:
        !Platform.isWindows || Platform.environment['FUNDUS_LIVE_HTTPS'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
